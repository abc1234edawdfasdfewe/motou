/* 墨投网页发送端：可读文档导入层。
 * 所有格式均在浏览器本地解析，只输出经白名单清洗的语义 HTML。
 * 加密、密码保护或 DRM 内容只检测并拒绝，不尝试解密。 */
(function (root) {
  'use strict';

  var MAX_FILE_BYTES = 150 * 1024 * 1024;
  var MAX_UNZIPPED_BYTES = 220 * 1024 * 1024;
  var MAX_ZIP_ENTRIES = 12000;
  var MAX_ZIP_ENTRY_UNZIPPED_BYTES = 32 * 1024 * 1024;
  var MAX_RESULT_CHARS = 4 * 1024 * 1024;
  var MAX_INLINE_IMAGE_BYTES = 2 * 1024 * 1024;
  var MAX_INLINE_IMAGES_TOTAL = 10 * 1024 * 1024;
  var MAX_SPREADSHEET_ROWS = 3000;
  var MAX_SPREADSHEET_COLUMNS = 200;
  var MAX_SPREADSHEET_CELLS = 60000;
  var MAX_SPREADSHEET_SHEETS = 200;
  var MAX_SPREADSHEET_CELL_CHARS = 32768;
  var MAX_SPREADSHEET_TEXT_CHARS = 400000;
  var MAX_PPT_RECORD_DEPTH = 64;
  var MAX_PPT_RECORDS = 100000;
  var CONTROLLED_HTML_RESERVE = 512;

  function ImportError(code, message) {
    this.name = 'ImportError';
    this.code = code;
    this.message = message;
    if (Error.captureStackTrace) Error.captureStackTrace(this, ImportError);
  }
  ImportError.prototype = Object.create(Error.prototype);
  ImportError.prototype.constructor = ImportError;

  function fail(code, message) { throw new ImportError(code, message); }
  function ensure(condition, code, message) { if (!condition) fail(code, message); }

  function extensionOf(fileOrName) {
    var name = typeof fileOrName === 'string' ? fileOrName : ((fileOrName && fileOrName.name) || '');
    var match = String(name).toLowerCase().match(/\.([^.\\/]+)$/);
    return match ? match[1] : '';
  }

  function stemOf(name) {
    return String(name || '未命名文档').replace(/\.[^.\\/]+$/, '') || '未命名文档';
  }

  var FORMAT_LABELS = {
    txt: '纯文本', md: 'Markdown', markdown: 'Markdown', docx: 'Word', epub: 'EPUB', mobi: 'MOBI', azw: 'AZW', azw3: 'AZW3',
    ppt: 'PowerPoint 97-2003', pptx: 'PowerPoint', xls: 'Excel 97-2003', xlsx: 'Excel', doc: 'Word 97-2003'
  };

  function formatLabel(fileOrName) {
    return FORMAT_LABELS[extensionOf(fileOrName)] || '文档';
  }

  function isReadableFile(file) {
    var ext = extensionOf(file);
    if (FORMAT_LABELS[ext]) return true;
    var type = String((file && file.type) || '').toLowerCase();
    return type.indexOf('text/') === 0 || type === 'application/markdown' ||
      type === 'application/epub+zip' || type === 'application/x-mobipocket-ebook' ||
      type === 'application/x-mobi8-ebook' || type === 'application/vnd.amazon.ebook' ||
      type === 'application/msword' || type === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
      type === 'application/vnd.ms-powerpoint' ||
      type === 'application/vnd.openxmlformats-officedocument.presentationml.presentation' ||
      type === 'application/vnd.ms-excel' ||
      type === 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }

  function esc(value) {
    return String(value == null ? '' : value).replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function safeHref(value) {
    var v = String(value || '').trim();
    if (!v) return '';
    if (/^https?:\/\//i.test(v) || /^mailto:/i.test(v) || /^#/i.test(v)) return v;
    return '';
  }

  function safeImageSrc(value) {
    var v = String(value || '').trim();
    if (/^data:image\/(?:png|jpe?g|gif|webp);base64,[a-z0-9+/=\s]+$/i.test(v)) return v;
    return '';
  }

  var TAG_KEEP = {
    P: 1, H1: 1, H2: 1, H3: 1, H4: 1, UL: 1, OL: 1, LI: 1, BLOCKQUOTE: 1,
    STRONG: 1, EM: 1, B: 1, I: 1, U: 1, S: 1, BR: 1, HR: 1, PRE: 1, CODE: 1,
    FIGURE: 1, FIGCAPTION: 1, IMG: 1, A: 1, TABLE: 1, THEAD: 1, TBODY: 1,
    TFOOT: 1, TR: 1, TH: 1, TD: 1, SUP: 1, SUB: 1, SECTION: 1
  };
  var TAG_DROP = {
    SCRIPT: 1, STYLE: 1, IFRAME: 1, NOSCRIPT: 1, FORM: 1, BUTTON: 1, INPUT: 1,
    SELECT: 1, TEXTAREA: 1, OBJECT: 1, EMBED: 1, VIDEO: 1, AUDIO: 1, SVG: 1,
    CANVAS: 1, META: 1, LINK: 1, BASE: 1, TEMPLATE: 1
  };

  /** 白名单清洗：拆掉未知标签但保留文字，主动内容整棵删除。 */
  function sanitizeHtml(html) {
    var doc = new DOMParser().parseFromString('<div id="__motou_root">' + String(html || '') + '</div>', 'text/html');
    var container = doc.getElementById('__motou_root');
    if (!container) return '';

    (function walk(parent) {
      Array.prototype.slice.call(parent.childNodes).forEach(function (node) {
        if (node.nodeType === 8) { node.remove(); return; }
        if (node.nodeType !== 1) return;
        var tag = node.tagName;
        if (TAG_DROP[tag]) { node.remove(); return; }
        if (!TAG_KEEP[tag]) {
          walk(node);
          while (node.firstChild) parent.insertBefore(node.firstChild, node);
          node.remove();
          return;
        }

        var href = tag === 'A' ? safeHref(node.getAttribute('href')) : '';
        var src = tag === 'IMG' ? safeImageSrc(node.getAttribute('src')) : '';
        var alt = tag === 'IMG' ? String(node.getAttribute('alt') || '').slice(0, 300) : '';
        var colspan = (tag === 'TD' || tag === 'TH') ? node.getAttribute('colspan') : '';
        var rowspan = (tag === 'TD' || tag === 'TH') ? node.getAttribute('rowspan') : '';
        Array.prototype.slice.call(node.attributes).forEach(function (attr) { node.removeAttribute(attr.name); });
        if (href) node.setAttribute('href', href);
        if (src) node.setAttribute('src', src);
        if (alt) node.setAttribute('alt', alt);
        if (/^\d{1,2}$/.test(colspan || '') && Number(colspan) > 1) node.setAttribute('colspan', colspan);
        if (/^\d{1,2}$/.test(rowspan || '') && Number(rowspan) > 1) node.setAttribute('rowspan', rowspan);
        walk(node);
        if (tag === 'IMG' && !node.getAttribute('src')) {
          if (alt) node.replaceWith(doc.createTextNode(alt)); else node.remove();
        }
      });
    })(container);
    return container.innerHTML.trim();
  }

  function trimResult(body) {
    if (body.length <= MAX_RESULT_CHARS) return body;
    var notice = '<p><strong>内容过长，已在网页端安全截断。</strong></p>';
    var contentBudget = Math.max(0, MAX_RESULT_CHARS - notice.length);
    var shortened = body.slice(0, contentBudget);
    var lastClose = shortened.lastIndexOf('>');
    if (lastClose > contentBudget * 0.9) shortened = shortened.slice(0, lastClose + 1);
    return shortened + notice;
  }

  /** 所有语义 HTML 的最终出口：先白名单清洗，再硬性封顶 4 MiB。 */
  function finalizeHtml(html) {
    return trimResult(sanitizeHtml(html));
  }

  function createHtmlBudget() {
    return { parts: [], length: 0, truncated: false, limit: MAX_RESULT_CHARS - CONTROLLED_HTML_RESERVE };
  }

  /** 在自有循环中提前停止累加，避免先 join 出超大中间字符串。 */
  function appendHtmlBudget(budget, html, separator) {
    if (budget.truncated) return false;
    var value = String(html || '');
    if (!value) return true;
    var prefix = budget.parts.length ? String(separator || '') : '';
    var remaining = budget.limit - budget.length;
    if (remaining <= prefix.length) {
      budget.truncated = true;
      return false;
    }
    var available = remaining - prefix.length;
    if (value.length > available) {
      value = value.slice(0, available);
      budget.truncated = true;
    }
    budget.parts.push(prefix + value);
    budget.length += prefix.length + value.length;
    return !budget.truncated;
  }

  function finishHtmlBudget(budget, notice) {
    var html = budget.parts.join('');
    if (budget.truncated) html += notice || '<p><strong>内容过长，已在网页端安全截断。</strong></p>';
    return finalizeHtml(html);
  }

  function readFileBytes(file) {
    if (!file) return Promise.reject(new ImportError('invalid', '未选择文件'));
    if (typeof file.size === 'number' && file.size > MAX_FILE_BYTES) {
      return Promise.reject(new ImportError('too-large', '文件超过 150 MB，为避免浏览器内存溢出已停止解析'));
    }
    try {
      return Promise.resolve(file.arrayBuffer()).then(function (buffer) { return new Uint8Array(buffer); });
    } catch (error) {
      return Promise.reject(error);
    }
  }

  function decode(bytes, encoding) {
    try { return new TextDecoder(encoding || 'utf-8').decode(bytes); }
    catch (_) { return new TextDecoder('utf-8').decode(bytes); }
  }

  function decodeXml(bytes) {
    if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) return decode(bytes, 'utf-16le');
    if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) return decode(bytes, 'utf-16be');
    var initial = decode(bytes, 'utf-8');
    var declared = initial.slice(0, 240).match(/encoding=["']([^"']+)["']/i);
    if (declared && !/^utf-?8$/i.test(declared[1])) return decode(bytes, declared[1]);
    return initial;
  }

  function parseXml(text, label) {
    var doc = new DOMParser().parseFromString(String(text || ''), 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) fail('corrupt', (label || 'XML') + '结构损坏');
    return doc;
  }

  function localElements(node, name) {
    return Array.prototype.slice.call(node.getElementsByTagNameNS('*', name));
  }

  function firstLocal(node, name) { return localElements(node, name)[0] || null; }

  function markdownDocument(text, fileName) {
    ensure(root.marked && typeof root.marked.parse === 'function', 'component', 'Markdown 组件未加载');
    var rendered;
    try { rendered = root.marked.parse(String(text || ''), { gfm: true, breaks: false, async: false }); }
    catch (_) { fail('corrupt', 'Markdown 解析失败'); }
    var body = sanitizeHtml(rendered);
    ensure(body, 'empty', 'Markdown 没有可读内容');
    var doc = new DOMParser().parseFromString('<div id="r">' + body + '</div>', 'text/html');
    var holder = doc.getElementById('r');
    var firstH1 = holder && holder.querySelector('h1');
    var title = firstH1 ? firstH1.textContent.trim() : stemOf(fileName);
    if (firstH1 && title) firstH1.remove();
    return { title: title || stemOf(fileName), body: finalizeHtml(holder ? holder.innerHTML : body), kind: 'markdown', format: 'Markdown' };
  }

  function parseMarkdownFile(file) {
    // Markdown can be arbitrarily large too; route it through the same bounded
    // byte reader as ebooks and Office files instead of File.text().
    return readFileBytes(file).then(function (bytes) {
      var limited = bytes.subarray(0, Math.min(bytes.length, MAX_RESULT_CHARS));
      var text = decode(limited, 'utf-8').replace(/^\uFEFF/, '');
      if (limited.length < bytes.length) text += '\n\n**Markdown 过长，已在网页端安全截断。**';
      return markdownDocument(text, file.name);
    });
  }

  function plainTextDocument(text, fileName, sourceTruncated) {
    var normalized = String(text || '').replace(/^\uFEFF/, '').trim();
    ensure(normalized, 'empty', '文本文件没有可读内容');
    var lines = normalized.split('\n'), title = '', rest = normalized;
    if (lines.length > 1 && lines[0].trim().length > 0 && lines[0].trim().length <= 30) {
      title = lines[0].trim();
      rest = lines.slice(1).join('\n');
    }
    var budget = createHtmlBudget();
    var paragraphs = rest.split(/\n{2,}/);
    for (var i = 0; i < paragraphs.length; i++) {
      var paragraph = paragraphs[i].trim();
      if (!paragraph) continue;
      if (!appendHtmlBudget(budget, '<p>' + esc(paragraph).replace(/\n/g, '<br>') + '</p>')) break;
    }
    if (sourceTruncated) budget.truncated = true;
    var body = finishHtmlBudget(budget);
    ensure(body, 'empty', '文本文件没有可读内容');
    return { title: title || stemOf(fileName), body: body, kind: 'text', format: 'TXT' };
  }

  function parseTextFile(file) {
    return readFileBytes(file).then(function (bytes) {
      var limited = bytes.subarray(0, Math.min(bytes.length, MAX_RESULT_CHARS));
      return plainTextDocument(decode(limited, 'utf-8'), file.name, limited.length < bytes.length);
    });
  }

  function exactArrayBuffer(bytes) {
    if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) return bytes.buffer;
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  }

  function parseDocxFile(file) {
    // 先执行文件大小与 ZIP 中央目录预检，再允许 Mammoth 解压/建模。
    return readFileBytes(file).then(function (bytes) {
      preflightZipCentralDirectory(bytes, 'DOCX');
      ensure(root.mammoth && typeof root.mammoth.convertToHtml === 'function', 'component', 'DOCX 组件未加载');
      return root.mammoth.convertToHtml({ arrayBuffer: exactArrayBuffer(bytes) });
    }).then(function (result) {
      var body = finalizeHtml((result && result.value) || '');
      ensure(body && body.replace(/<[^>]+>/g, '').trim(), 'empty', 'DOCX 中没有可读正文');
      return { title: stemOf(file.name), body: body, kind: 'docx', format: 'DOCX' };
    }).catch(function (error) {
      if (error instanceof ImportError) throw error;
      if (/encrypt|password/i.test(String(error && error.message))) fail('encrypted', 'DOCX 已加密/受密码保护');
      fail('corrupt', 'DOCX 解析失败或文件已损坏');
    });
  }

  function isOle(bytes) {
    return bytes.length >= 8 && bytes[0] === 0xd0 && bytes[1] === 0xcf && bytes[2] === 0x11 && bytes[3] === 0xe0 &&
      bytes[4] === 0xa1 && bytes[5] === 0xb1 && bytes[6] === 0x1a && bytes[7] === 0xe1;
  }

  function isZip(bytes) {
    return bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b &&
      ((bytes[2] === 3 && bytes[3] === 4) || (bytes[2] === 5 && bytes[3] === 6) || (bytes[2] === 7 && bytes[3] === 8));
  }

  function u16le(b, p) { return (b[p] | (b[p + 1] << 8)) >>> 0; }
  function u32le(b, p) { return (u16le(b, p) | (u16le(b, p + 2) << 16)) >>> 0; }
  function u16be(b, p) { return ((b[p] << 8) | b[p + 1]) >>> 0; }
  function u32be(b, p) { return ((b[p] * 0x1000000) + (b[p + 1] << 16) + (b[p + 2] << 8) + b[p + 3]) >>> 0; }

  function findZipEocd(bytes) {
    var minimum = Math.max(0, bytes.length - 22 - 0xffff);
    for (var p = bytes.length - 22; p >= minimum; p--) {
      if (u32le(bytes, p) !== 0x06054b50) continue;
      var commentLength = u16le(bytes, p + 20);
      if (p + 22 + commentLength === bytes.length) return p;
    }
    return -1;
  }

  /**
   * 只读 ZIP central-directory 预检。它不解压数据，但会在 Mammoth、
   * SheetJS 或 fflate 获得容器前拒绝加密、ZIP64/分卷、越界和压缩炸弹元数据。
   */
  function preflightZipCentralDirectory(bytes, label) {
    label = label || 'ZIP';
    ensure(isZip(bytes), 'corrupt', label + '不是有效的 ZIP 容器');
    var eocd = findZipEocd(bytes);
    ensure(eocd >= 0, 'corrupt', label + '缺少有效的中央目录');

    var disk = u16le(bytes, eocd + 4), centralDisk = u16le(bytes, eocd + 6);
    var entriesOnDisk = u16le(bytes, eocd + 8), entryCount = u16le(bytes, eocd + 10);
    var centralSize = u32le(bytes, eocd + 12), centralOffset = u32le(bytes, eocd + 16);
    if (entryCount === 0xffff || entriesOnDisk === 0xffff || centralSize === 0xffffffff || centralOffset === 0xffffffff) {
      fail('too-large', label + '使用 ZIP64，超出网页端安全解析范围');
    }
    ensure(disk === 0 && centralDisk === 0 && entriesOnDisk === entryCount, 'corrupt', label + '为分卷 ZIP，不支持解析');
    ensure(entryCount <= MAX_ZIP_ENTRIES, 'too-large', label + '压缩包文件数超过 ' + MAX_ZIP_ENTRIES);
    var centralEnd = centralOffset + centralSize;
    ensure(centralEnd >= centralOffset && centralEnd <= eocd, 'corrupt', label + '中央目录越界');

    var p = centralOffset, totalExpanded = 0;
    for (var index = 0; index < entryCount; index++) {
      ensure(p + 46 <= centralEnd && u32le(bytes, p) === 0x02014b50, 'corrupt', label + '中央目录项损坏');
      var flags = u16le(bytes, p + 8), method = u16le(bytes, p + 10);
      var packed = u32le(bytes, p + 20), expanded = u32le(bytes, p + 24);
      var nameLength = u16le(bytes, p + 28), extraLength = u16le(bytes, p + 30), commentLength = u16le(bytes, p + 32);
      var localOffset = u32le(bytes, p + 42);
      if (packed === 0xffffffff || expanded === 0xffffffff || localOffset === 0xffffffff) {
        fail('too-large', label + '包含 ZIP64 目录项，已停止解析');
      }
      if (flags & 0x0001 || flags & 0x0040) fail('encrypted', label + '容器已加密/受密码保护');
      ensure(method === 0 || method === 8, 'corrupt', label + '使用不受支持的 ZIP 压缩方式');
      ensure(expanded <= MAX_ZIP_ENTRY_UNZIPPED_BYTES, 'too-large', label + '单个解压项超过 32 MB，已停止解析');
      totalExpanded += expanded;
      ensure(totalExpanded <= MAX_UNZIPPED_BYTES, 'too-large', label + '声明的解压总量超过 220 MB，已停止解析');

      var next = p + 46 + nameLength + extraLength + commentLength;
      ensure(nameLength > 0 && next >= p && next <= centralEnd, 'corrupt', label + '中央目录长度无效');
      ensure(localOffset + 30 <= centralOffset && u32le(bytes, localOffset) === 0x04034b50, 'corrupt', label + '本地文件头损坏');
      var localFlags = u16le(bytes, localOffset + 6), localMethod = u16le(bytes, localOffset + 8);
      var localNameLength = u16le(bytes, localOffset + 26), localExtraLength = u16le(bytes, localOffset + 28);
      if (localFlags & 0x0001 || localFlags & 0x0040) fail('encrypted', label + '容器已加密/受密码保护');
      ensure(localMethod === method, 'corrupt', label + '压缩方式元数据不一致');
      var dataOffset = localOffset + 30 + localNameLength + localExtraLength;
      ensure(dataOffset >= localOffset && dataOffset + packed >= dataOffset && dataOffset + packed <= centralOffset,
        'corrupt', label + '压缩数据越界');
      p = next;
    }
    ensure(p === centralEnd, 'corrupt', label + '中央目录大小不一致');
    return { entries: entryCount, expandedBytes: totalExpanded, centralBytes: centralSize };
  }

  function assertZipNotEncrypted(bytes) {
    for (var p = 0; p + 30 <= bytes.length;) {
      if (u32le(bytes, p) !== 0x04034b50) { p++; continue; }
      var flags = u16le(bytes, p + 6);
      if (flags & 1) fail('encrypted', 'ZIP 容器已加密，不支持密码或 DRM 解锁');
      var packed = u32le(bytes, p + 18);
      var nameLen = u16le(bytes, p + 26), extraLen = u16le(bytes, p + 28);
      var next = p + 30 + nameLen + extraLen + packed;
      p = next > p && next <= bytes.length ? next : p + 4;
    }
  }

  function unzipSafe(bytes, label) {
    ensure(root.fflate && typeof root.fflate.unzipSync === 'function', 'component', 'ZIP 组件未加载');
    preflightZipCentralDirectory(bytes, label || 'ZIP');
    assertZipNotEncrypted(bytes);
    var total = 0, count = 0;
    try {
      return root.fflate.unzipSync(bytes, {
        filter: function (entry) {
          total += Number(entry.originalSize || entry.size || 0);
          count++;
          if (total > MAX_UNZIPPED_BYTES) fail('too-large', '解压后内容超过 220 MB，已停止解析');
          if (count > MAX_ZIP_ENTRIES) fail('too-large', '压缩包文件数过多，已停止解析');
          return true;
        }
      });
    } catch (error) {
      if (error instanceof ImportError) throw error;
      if (/encrypt|password/i.test(String(error && error.message))) fail('encrypted', '压缩容器已加密，无法读取');
      fail('corrupt', (label || 'ZIP') + '解压失败或文件已损坏');
    }
  }

  function zipEntry(entries, path) {
    if (entries[path]) return entries[path];
    var lower = String(path).toLowerCase();
    var key = Object.keys(entries).find(function (item) { return item.toLowerCase() === lower; });
    return key ? entries[key] : null;
  }

  function normalizeZipPath(baseFile, target) {
    var raw = String(target || '').split('#')[0].split('?')[0].replace(/\\/g, '/');
    try { raw = decodeURIComponent(raw); } catch (_) {}
    var parts = raw.charAt(0) === '/' ? [] : String(baseFile || '').split('/').slice(0, -1);
    raw.replace(/^\/+/, '').split('/').forEach(function (part) {
      if (!part || part === '.') return;
      if (part === '..') { if (parts.length) parts.pop(); }
      else parts.push(part);
    });
    return parts.join('/');
  }

  function mimeForImage(path) {
    var ext = extensionOf(path);
    return { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp' }[ext] || '';
  }

  function bytesToBase64(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 0x8000) {
      out += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(bytes.length, i + 0x8000)));
    }
    return btoa(out);
  }

  function inlineZipImages(html, basePath, entries, budget) {
    var doc = new DOMParser().parseFromString('<div id="r">' + String(html || '') + '</div>', 'text/html');
    var holder = doc.getElementById('r');
    if (!holder) return '';
    Array.prototype.slice.call(holder.querySelectorAll('img')).forEach(function (img) {
      var src = img.getAttribute('src') || '';
      if (!src || /^(?:data:|https?:|blob:)/i.test(src)) return;
      var path = normalizeZipPath(basePath, src);
      var data = zipEntry(entries, path), mime = mimeForImage(path);
      if (!data || !mime || data.length > MAX_INLINE_IMAGE_BYTES || budget.used + data.length > MAX_INLINE_IMAGES_TOTAL) {
        img.removeAttribute('src');
        return;
      }
      budget.used += data.length;
      img.setAttribute('src', 'data:' + mime + ';base64,' + bytesToBase64(data));
    });
    return holder.innerHTML;
  }

  function epubEncryptionCheck(entries) {
    if (zipEntry(entries, 'META-INF/license.lcpl')) fail('drm', 'EPUB 包含 Readium LCP DRM，已拒绝解析');
    if (hasEpubRightsProtection(entries)) fail('drm', 'EPUB 包含 rights.xml 权利保护声明，已拒绝解析');
    var encryption = zipEntry(entries, 'META-INF/encryption.xml');
    if (!encryption) return;
    var doc = parseXml(decodeXml(encryption), 'EPUB encryption.xml');
    var encrypted = localElements(doc, 'EncryptedData');
    ensure(encrypted.length, 'drm', 'EPUB encryption.xml 不含可验证的标准字体混淆记录');
    encrypted.forEach(function (item) {
      var method = firstLocal(item, 'EncryptionMethod');
      var ref = firstLocal(item, 'CipherReference');
      var algorithm = method && (method.getAttribute('Algorithm') || method.getAttribute('algorithm'));
      var uri = ref && (ref.getAttribute('URI') || ref.getAttribute('Uri'));
      if (!isAllowedEpubFontObfuscation(algorithm, uri)) {
        fail('drm', 'EPUB 含未知加密算法或非字体资源保护，已拒绝解析');
      }
    });
  }

  function hasEpubRightsProtection(entries) {
    return !!zipEntry(entries || {}, 'META-INF/rights.xml');
  }

  function isAllowedEpubFontObfuscation(algorithm, uri) {
    var standard = algorithm === 'http://www.idpf.org/2008/embedding' ||
      algorithm === 'http://ns.adobe.com/pdf/enc#RC';
    var target = String(uri || '').split(/[?#]/)[0];
    return standard && /\.(?:ttf|otf)$/i.test(target);
  }

  function parseEpubBytes(bytes, fileName) {
    var entries = unzipSafe(bytes, 'EPUB');
    epubEncryptionCheck(entries);
    var containerBytes = zipEntry(entries, 'META-INF/container.xml');
    ensure(containerBytes, 'corrupt', 'EPUB 缺少 META-INF/container.xml');
    var container = parseXml(decodeXml(containerBytes), 'EPUB container.xml');
    var rootfile = firstLocal(container, 'rootfile');
    var opfPath = rootfile && rootfile.getAttribute('full-path');
    ensure(opfPath, 'corrupt', 'EPUB 缺少 OPF 根文档');
    var opfBytes = zipEntry(entries, opfPath);
    ensure(opfBytes, 'corrupt', 'EPUB OPF 文档不存在');
    var opf = parseXml(decodeXml(opfBytes), 'EPUB OPF');
    var titleNode = firstLocal(opf, 'title');
    var title = (titleNode && titleNode.textContent.trim()) || stemOf(fileName);
    var manifest = {};
    localElements(opf, 'item').forEach(function (item) {
      var id = item.getAttribute('id');
      if (id) manifest[id] = {
        path: normalizeZipPath(opfPath, item.getAttribute('href') || ''),
        media: item.getAttribute('media-type') || '', properties: item.getAttribute('properties') || ''
      };
    });
    var spine = localElements(opf, 'itemref').map(function (itemref) { return manifest[itemref.getAttribute('idref')]; })
      .filter(function (item) { return item && /(?:xhtml|html|xml)/i.test(item.media || item.path); });
    if (!spine.length) {
      spine = Object.keys(manifest).map(function (id) { return manifest[id]; })
        .filter(function (item) { return /(?:application\/xhtml\+xml|text\/html)/i.test(item.media); });
    }
    ensure(spine.length, 'empty', 'EPUB 书脊中没有可读章节');
    var output = createHtmlBudget(), imageBudget = { used: 0 };
    var spineLimit = Math.min(spine.length, 600);
    for (var index = 0; index < spineLimit; index++) {
      var item = spine[index];
      var chapterBytes = zipEntry(entries, item.path);
      if (!chapterBytes) continue;
      var text = decodeXml(chapterBytes);
      var chapterDoc = new DOMParser().parseFromString(text, 'text/html');
      var rawBody = chapterDoc.body ? chapterDoc.body.innerHTML : text;
      rawBody = inlineZipImages(rawBody, item.path, entries, imageBudget);
      var body = sanitizeHtml(rawBody);
      if (!body || !body.replace(/<[^>]+>/g, '').trim()) continue;
      var heading = chapterDoc.querySelector('h1,h2,h3,title');
      var chapterTitle = heading && heading.textContent.trim();
      var hasHeading = /^\s*<h[1-4][\s>]/i.test(body);
      if (!appendHtmlBudget(output, '<section>' + (hasHeading ? '' : '<h2>' + esc(chapterTitle || ('第 ' + (index + 1) + ' 章')) + '</h2>') + body + '</section>', '<hr>')) break;
    }
    if (spine.length > spineLimit) output.truncated = true;
    ensure(output.parts.length, 'empty', 'EPUB 中没有可读正文');
    return { title: title, body: finishHtmlBudget(output), kind: 'epub', format: 'EPUB' };
  }

  function parseEpubFile(file) {
    return readFileBytes(file).then(function (bytes) { return parseEpubBytes(bytes, file.name); });
  }

  function relationshipId(node) {
    if (!node) return '';
    // p:sldId 同时包含普通 id="256" 与关系属性 r:id="rId2"。
    // 只按 localName 查找会误取普通 id，导致合法 PPTX 被判断为“没有幻灯片”。
    var relationshipNamespace = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    var value = node.getAttributeNS && node.getAttributeNS(relationshipNamespace, 'id');
    if (value) return value;
    value = node.getAttribute && node.getAttribute('r:id');
    if (value) return value;
    for (var i = 0; i < node.attributes.length; i++) {
      var attr = node.attributes[i];
      if ((attr.prefix === 'r' || attr.namespaceURI === relationshipNamespace) &&
          (attr.localName || attr.name) === 'id') return attr.value;
    }
    return '';
  }

  function xmlNodeText(node) {
    return localElements(node, 't').map(function (textNode) { return textNode.textContent || ''; }).join('').trim();
  }

  function pptxSlidePaths(entries) {
    var presentationBytes = zipEntry(entries, 'ppt/presentation.xml');
    var relBytes = zipEntry(entries, 'ppt/_rels/presentation.xml.rels');
    if (!presentationBytes || !relBytes) {
      return Object.keys(entries).filter(function (path) { return /^ppt\/slides\/slide\d+\.xml$/i.test(path); })
        .sort(function (a, b) { return Number((a.match(/slide(\d+)/i) || [0, 0])[1]) - Number((b.match(/slide(\d+)/i) || [0, 0])[1]); });
    }
    var presentation = parseXml(decodeXml(presentationBytes), 'presentation.xml');
    var rels = parseXml(decodeXml(relBytes), 'presentation.xml.rels');
    var relMap = {};
    localElements(rels, 'Relationship').forEach(function (rel) { relMap[rel.getAttribute('Id')] = rel.getAttribute('Target'); });
    return localElements(presentation, 'sldId').map(function (slideId) {
      var relId = relationshipId(slideId);
      return relMap[relId] ? normalizeZipPath('ppt/presentation.xml', relMap[relId]) : '';
    }).filter(Boolean);
  }

  function parsePptxSlide(xml, index) {
    var doc = parseXml(xml, '第 ' + (index + 1) + ' 张幻灯片');
    var title = '', blocks = [];
    localElements(doc, 'sp').forEach(function (shape) {
      var paragraphs = localElements(shape, 'p').map(xmlNodeText).filter(Boolean);
      if (!paragraphs.length) return;
      var placeholder = firstLocal(shape, 'ph');
      var placeholderType = placeholder && placeholder.getAttribute('type');
      if (!title && /^(?:title|ctrTitle)$/.test(placeholderType || '')) title = paragraphs.join(' ');
      else blocks.push.apply(blocks, paragraphs);
    });
    var tables = localElements(doc, 'tbl').map(function (table) {
      var rows = localElements(table, 'tr').map(function (row) {
        return localElements(row, 'tc').map(function (cell) { return xmlNodeText(cell); });
      }).filter(function (row) { return row.some(Boolean); });
      if (!rows.length) return '';
      return '<table><tbody>' + rows.map(function (row) {
        return '<tr>' + row.map(function (cell) { return '<td>' + esc(cell) + '</td>'; }).join('') + '</tr>';
      }).join('') + '</tbody></table>';
    }).filter(Boolean);
    if (!title && blocks.length) title = blocks.shift();
    var body = '<section><h2>' + esc('幻灯片 ' + (index + 1) + (title ? '：' + title : '')) + '</h2>' +
      blocks.map(function (line) { return '<p>' + esc(line) + '</p>'; }).join('') + tables.join('') + '</section>';
    return { body: body, hasText: !!(title || blocks.length || tables.length) };
  }

  function parsePptxBytes(bytes, fileName) {
    if (isOle(bytes)) fail('encrypted', 'PPTX 是加密 Office 容器，请先在 PowerPoint 中取消密码');
    var entries = unzipSafe(bytes, 'PPTX');
    if (zipEntry(entries, 'EncryptionInfo') || zipEntry(entries, 'EncryptedPackage')) {
      fail('encrypted', 'PPTX 已加密/受密码保护');
    }
    var paths = pptxSlidePaths(entries);
    ensure(paths.length, 'corrupt', 'PPTX 中没有幻灯片');
    var output = createHtmlBudget();
    var pathLimit = Math.min(paths.length, 1000);
    for (var index = 0; index < pathLimit; index++) {
      var path = paths[index];
      var data = zipEntry(entries, path);
      if (!data) continue;
      var item = parsePptxSlide(decodeXml(data), index);
      if (item && item.hasText && !appendHtmlBudget(output, item.body, '<hr>')) break;
    }
    if (paths.length > pathLimit) output.truncated = true;
    ensure(output.parts.length, 'empty', 'PPTX 中没有可提取文字');
    return { title: stemOf(fileName), body: finishHtmlBudget(output), kind: 'presentation', format: 'PPTX' };
  }

  function cfbRead(bytes) {
    ensure(root.XLSX && root.XLSX.CFB, 'component', 'Office 二进制组件未加载');
    try { return root.XLSX.CFB.read(bytes, { type: 'array' }); }
    catch (_) { fail('corrupt', 'OLE Office 文件容器损坏'); }
  }

  function cfbFind(cfb, name) {
    try { return root.XLSX.CFB.find(cfb, name); } catch (_) { return null; }
  }

  function entryBytes(entry) {
    if (!entry || !entry.content) return null;
    return entry.content instanceof Uint8Array ? entry.content : new Uint8Array(entry.content);
  }

  function assertNoEncryptedOfficeCfb(cfb) {
    if (cfbFind(cfb, 'EncryptedPackage') || cfbFind(cfb, 'EncryptionInfo')) {
      fail('encrypted', 'Office 文件已加密/受密码保护');
    }
  }

  function pptContainsCryptRecord(bytes, start, end, state, depth) {
    state = state || { records: 0 };
    depth = depth || 0;
    if (depth > MAX_PPT_RECORD_DEPTH) fail('too-large', 'PPT 记录嵌套层级过深，已停止预检');
    var p = start || 0, limit = Math.min(end == null ? bytes.length : end, bytes.length);
    while (p + 8 <= limit) {
      state.records++;
      if (state.records > MAX_PPT_RECORDS) fail('too-large', 'PPT 记录数过多，已停止预检');
      var ver = u16le(bytes, p) & 0x000f, type = u16le(bytes, p + 2), len = u32le(bytes, p + 4);
      if (type === 0x2f14) return true;
      var payload = p + 8, next = payload + len;
      if (next < payload || next > limit) break;
      if (ver === 0x0f && len >= 8 && pptContainsCryptRecord(bytes, payload, next, state, depth + 1)) return true;
      p = next;
    }
    return false;
  }

  function fallbackPptText(powerPointBytes) {
    var slides = [], retainedChars = 0;
    function scan(start, end, current, depth) {
      if (depth > MAX_PPT_RECORD_DEPTH) fail('too-large', 'PPT 记录嵌套层级过深，已停止解析');
      var p = start;
      while (p + 8 <= end && slides.length <= 1000 && retainedChars < MAX_RESULT_CHARS) {
        var ver = u16le(powerPointBytes, p) & 0xf, type = u16le(powerPointBytes, p + 2), len = u32le(powerPointBytes, p + 4);
        var from = p + 8, to = from + len;
        if (to < from || to > end) break;
        var target = current;
        if (type === 0x03ee) { target = []; slides.push(target); }
        if (type === 0x0fa0 || type === 0x0fa8) {
          var value = decode(powerPointBytes.subarray(from, to), type === 0x0fa0 ? 'utf-16le' : 'windows-1252').replace(/\0/g, '');
          value = value.slice(0, Math.max(0, MAX_RESULT_CHARS - retainedChars));
          retainedChars += value.length;
          target.push(value);
        }
        else if (ver === 0x0f && len >= 8) scan(from, to, target, depth + 1);
        p = to;
      }
    }
    scan(0, powerPointBytes.length, [], 0);
    return slides.map(function (parts) { return parts.join('\n'); }).filter(function (text) { return text.trim(); });
  }

  function slidesToHtml(slides) {
    var output = createHtmlBudget(), limit = Math.min(slides.length, 1000);
    for (var index = 0; index < limit; index++) {
      var slide = slides[index];
      var lines = String(slide || '').replace(/\0/g, '').split(/[\r\n]+/).map(function (s) { return s.trim(); }).filter(Boolean);
      var title = lines.shift() || '';
      var section = '<section><h2>' + esc('幻灯片 ' + (index + 1) + (title ? '：' + title : '')) + '</h2>' +
        lines.map(function (line) { return '<p>' + esc(line) + '</p>'; }).join('') + '</section>';
      if (!appendHtmlBudget(output, section, '<hr>')) break;
    }
    if (slides.length > limit) output.truncated = true;
    return finishHtmlBudget(output);
  }

  function parsePptBytes(bytes, fileName) {
    ensure(isOle(bytes), 'corrupt', 'PPT 不是有效的 PowerPoint 97-2003 文件');
    var cfb = cfbRead(bytes);
    assertNoEncryptedOfficeCfb(cfb);
    var currentUser = entryBytes(cfbFind(cfb, 'Current User'));
    if (currentUser && currentUser.length >= 16 && u32le(currentUser, 12) === 0xf3d1c4df) {
      fail('encrypted', 'PPT 已加密/受密码保护');
    }
    var powerPoint = entryBytes(cfbFind(cfb, 'PowerPoint Document'));
    ensure(powerPoint, 'corrupt', 'PPT 缺少 PowerPoint Document 数据流');
    if (pptContainsCryptRecord(powerPoint)) fail('encrypted', 'PPT 包含加密会话，已拒绝解析');
    var slides = [];
    if (root.PPT && typeof root.PPT.parse_pptcfb === 'function') {
      try { slides = root.PPT.utils.to_text(root.PPT.parse_pptcfb(cfb, {})).filter(function (s) { return String(s || '').trim(); }); }
      catch (_) { slides = []; }
    }
    if (!slides.length) slides = fallbackPptText(powerPoint);
    ensure(slides.length, 'empty', 'PPT 中没有可提取文字，或版本不受支持');
    return { title: stemOf(fileName), body: slidesToHtml(slides), kind: 'presentation', format: 'PPT' };
  }

  function spreadsheetEncrypted(bytes, ext) {
    if (!isOle(bytes)) return false;
    var cfb = cfbRead(bytes);
    if (cfbFind(cfb, 'EncryptedPackage') || cfbFind(cfb, 'EncryptionInfo')) return true;
    if (ext !== 'xls') return false;
    var workbook = entryBytes(cfbFind(cfb, 'Workbook') || cfbFind(cfb, 'Book'));
    if (!workbook) return false;
    for (var p = 0; p + 4 <= workbook.length;) {
      var id = u16le(workbook, p), len = u16le(workbook, p + 2);
      if (id === 0x002f) return true; // BIFF FILEPASS
      p += 4 + len;
    }
    return false;
  }

  /**
   * Clamp a decoded SheetJS range before sheet_to_json sees it.  This is intentionally
   * independent of SheetJS so the boundary arithmetic can be regression-tested in Node.
   */
  function clampDecodedSheetRange(decoded) {
    var source = decoded || {};
    var sourceStart = source.s || {};
    var sourceEnd = source.e || {};
    var startRow = Number.isFinite(sourceStart.r) && sourceStart.r >= 0 ? Math.floor(sourceStart.r) : 0;
    var startColumn = Number.isFinite(sourceStart.c) && sourceStart.c >= 0 ? Math.floor(sourceStart.c) : 0;
    var endRow = Number.isFinite(sourceEnd.r) && sourceEnd.r >= startRow ? Math.floor(sourceEnd.r) : startRow;
    var endColumn = Number.isFinite(sourceEnd.c) && sourceEnd.c >= startColumn ? Math.floor(sourceEnd.c) : startColumn;
    var clampedEndRow = Math.min(endRow, startRow + MAX_SPREADSHEET_ROWS - 1);
    var clampedEndColumn = Math.min(endColumn, startColumn + MAX_SPREADSHEET_COLUMNS - 1);
    return {
      range: {
        s: { r: startRow, c: startColumn },
        e: { r: clampedEndRow, c: clampedEndColumn }
      },
      truncated: endRow > clampedEndRow || endColumn > clampedEndColumn ||
        startRow !== sourceStart.r || startColumn !== sourceStart.c
    };
  }

  function spreadsheetRangePlan(sheet, utils) {
    var ref = sheet && sheet['!ref'];
    if (!ref) return { range: { s: { r: 0, c: 0 }, e: { r: 0, c: 0 } }, truncated: false };
    try {
      return clampDecodedSheetRange(utils.decode_range(ref));
    } catch (_) {
      return {
        range: {
          s: { r: 0, c: 0 },
          e: { r: MAX_SPREADSHEET_ROWS - 1, c: MAX_SPREADSHEET_COLUMNS - 1 }
        },
        truncated: true
      };
    }
  }

  /** Keep the leading rows/cells that still fit in the cross-sheet output budget. */
  function takeSpreadsheetRows(rows, remainingCells, remainingTextChars) {
    var accepted = [], remaining = Math.max(0, Math.floor(Number(remainingCells) || 0));
    var textRemaining = remainingTextChars == null ? MAX_SPREADSHEET_TEXT_CHARS :
      Math.max(0, Math.floor(Number(remainingTextChars) || 0));
    var truncated = false, used = 0, usedTextChars = 0;
    for (var i = 0; i < rows.length; i++) {
      var raw = Array.prototype.slice.call(rows[i] || []);
      var clipped = raw.slice(0, MAX_SPREADSHEET_COLUMNS);
      if (raw.length > MAX_SPREADSHEET_COLUMNS) truncated = true;
      if (!clipped.length) continue;
      if (remaining <= 0) { truncated = true; break; }
      if (clipped.length > remaining) {
        clipped = clipped.slice(0, remaining);
        truncated = true;
      }
      clipped = clipped.map(function (cell) {
        var value = String(cell == null ? '' : cell);
        if (value.length > MAX_SPREADSHEET_CELL_CHARS) {
          value = value.slice(0, MAX_SPREADSHEET_CELL_CHARS);
          truncated = true;
        }
        if (value.length > textRemaining) {
          value = value.slice(0, textRemaining);
          truncated = true;
        }
        textRemaining -= value.length;
        usedTextChars += value.length;
        return value;
      });
      accepted.push(clipped);
      used += clipped.length;
      remaining -= clipped.length;
      if (remaining === 0 && i + 1 < rows.length) { truncated = true; break; }
    }
    return {
      rows: accepted, used: used, remaining: remaining, truncated: truncated,
      usedTextChars: usedTextChars, remainingTextChars: textRemaining
    };
  }

  /**
   * Extract bounded grids before HTML rendering.  In particular, `range` is passed to
   * sheet_to_json up front; slicing the returned rows is too late for a huge/dirty !ref.
   */
  function extractSpreadsheetGrid(workbook, utils) {
    var names = (workbook && workbook.SheetNames) || [];
    var limit = Math.min(names.length, MAX_SPREADSHEET_SHEETS);
    var remaining = MAX_SPREADSHEET_CELLS;
    var remainingTextChars = MAX_SPREADSHEET_TEXT_CHARS;
    var truncated = names.length > MAX_SPREADSHEET_SHEETS;
    var sheets = [];
    for (var sheetIndex = 0; sheetIndex < limit; sheetIndex++) {
      if (remaining <= 0) { truncated = true; break; }
      var sheetName = names[sheetIndex];
      var sheet = workbook.Sheets && workbook.Sheets[sheetName];
      if (!sheet) continue;
      var plan = spreadsheetRangePlan(sheet, utils);
      if (plan.truncated) truncated = true;
      var rows = utils.sheet_to_json(sheet, {
        header: 1, raw: false, defval: '', blankrows: false, range: plan.range
      });
      var selected = takeSpreadsheetRows(rows, remaining, remainingTextChars);
      if (selected.truncated) truncated = true;
      remaining = selected.remaining;
      remainingTextChars = selected.remainingTextChars;
      if (selected.rows.length) {
        sheets.push({ name: sheetName, index: sheetIndex, rows: selected.rows });
      }
      if (remaining === 0 && sheetIndex + 1 < names.length) {
        truncated = true;
        break;
      }
    }
    return {
      sheets: sheets,
      usedCells: MAX_SPREADSHEET_CELLS - remaining,
      remainingCells: remaining,
      usedTextChars: MAX_SPREADSHEET_TEXT_CHARS - remainingTextChars,
      remainingTextChars: remainingTextChars,
      truncated: truncated
    };
  }

  function parseSpreadsheetBytes(bytes, fileName) {
    ensure(root.XLSX && typeof root.XLSX.read === 'function', 'component', 'Excel 组件未加载');
    var ext = extensionOf(fileName);
    if (spreadsheetEncrypted(bytes, ext)) fail('encrypted', '表格已加密/受密码保护');
    if (isZip(bytes)) preflightZipCentralDirectory(bytes, 'XLSX');
    else if (ext === 'xlsx') fail('corrupt', 'XLSX 不是有效的 ZIP Office 容器');
    var workbook;
    try {
      workbook = root.XLSX.read(bytes, { type: 'array', cellDates: true, cellHTML: false, cellNF: false, bookVBA: false });
    } catch (error) {
      if (/password|encrypt|protected/i.test(String(error && error.message))) fail('encrypted', '表格已加密/受密码保护');
      fail('corrupt', '表格解析失败或文件已损坏');
    }
    var extracted = extractSpreadsheetGrid(workbook, root.XLSX.utils);
    var budget = createHtmlBudget();
    for (var sheetIndex = 0; sheetIndex < extracted.sheets.length; sheetIndex++) {
      var sheet = extracted.sheets[sheetIndex];
      var htmlRows = sheet.rows.map(function (row, rowIndex) {
        var tag = rowIndex === 0 ? 'th' : 'td';
        return '<tr>' + row.map(function (cell) { return '<' + tag + '>' + esc(cell) + '</' + tag + '>'; }).join('') + '</tr>';
      }).join('');
      if (!appendHtmlBudget(budget, '<section><h2>' + esc('工作表 ' + (sheet.index + 1) + '：' + sheet.name) +
        '</h2><table><tbody>' + htmlRows + '</tbody></table></section>', '<hr>')) break;
    }
    ensure(budget.parts.length, 'empty', '表格中没有可读单元格');
    if (extracted.truncated) {
      budget.truncated = true;
    }
    return {
      title: stemOf(fileName),
      body: finishHtmlBudget(budget, '<p><strong>表格过大，已按每表前 200 列/3000 行、跨表总 60000 个单元格及输出上限保留前部内容。</strong></p>'),
      kind: 'spreadsheet', format: ext.toUpperCase()
    };
  }

  function wordEncoding(word) {
    var lid = word.length >= 8 ? u16le(word, 6) : 0;
    if (lid === 0x0804 || lid === 0x1004) return 'gb18030';
    if (lid === 0x0404 || lid === 0x0c04 || lid === 0x1404) return 'big5';
    if (lid === 0x0411) return 'shift_jis';
    if (lid === 0x0412) return 'euc-kr';
    return 'windows-1252';
  }

  function cleanWordText(text) {
    var previous;
    text = String(text || '').replace(/[\x02\x05\x08]/g, '').replace(/\x07/g, '\t')
      .replace(/[\x0b\x0c]/g, '\n').replace(/\x0d/g, '\n');
    do {
      previous = text;
      text = text.replace(/\x13[^\x13\x14\x15]*\x14?([^\x13\x14\x15]*)\x15/g, '$1');
    } while (text !== previous);
    return text.replace(/[\x00-\x06\x0e-\x1f]/g, '');
  }

  function semanticPlainText(text) {
    var source = String(text || '');
    var sourceTruncated = source.length > MAX_RESULT_CHARS;
    var rows = source.slice(0, MAX_RESULT_CHARS).split(/\n+/);
    var output = createHtmlBudget(), tableRows = [];
    function flushTable() {
      if (!tableRows.length || output.truncated) return;
      appendHtmlBudget(output, '<table><tbody>' + tableRows.map(function (cells) {
        return '<tr>' + cells.map(function (cell) { return '<td>' + esc(cell) + '</td>'; }).join('') + '</tr>';
      }).join('') + '</tbody></table>');
      tableRows = [];
    }
    for (var i = 0; i < rows.length && !output.truncated; i++) {
      var line = rows[i].trim();
      if (!line) continue;
      if (line.indexOf('\t') >= 0) tableRows.push(line.split(/\t+/).map(function (cell) { return cell.trim(); }));
      else { flushTable(); appendHtmlBudget(output, '<p>' + esc(line) + '</p>'); }
    }
    flushTable();
    if (sourceTruncated) output.truncated = true;
    return finishHtmlBudget(output);
  }

  function extractDocText(word, table) {
    ensure(word.length >= 0x1aa && u16le(word, 0) === 0xa5ec, 'corrupt', '仅支持 Word 97-2003 二进制 .doc');
    var flags = u16le(word, 0x0a);
    if (flags & 0x0100 || flags & 0x8000) fail('encrypted', 'DOC 已加密/混淆保护，已拒绝解析');
    var ccpText = u32le(word, 0x4c), fcClx = u32le(word, 0x1a2), lcbClx = u32le(word, 0x1a6);
    var pos = fcClx, end = Math.min(table.length, fcClx + lcbClx);
    while (pos < end && table[pos] === 1) {
      ensure(pos + 3 <= end, 'corrupt', 'DOC 片段表损坏');
      pos += 3 + u16le(table, pos + 1);
    }
    if (pos < end && table[pos] === 2 && pos + 5 <= end) {
      var pieceSize = u32le(table, pos + 1), pieceStart = pos + 5;
      var count = (pieceSize - 4) / 12;
      ensure(count >= 1 && count === Math.floor(count), 'corrupt', 'DOC 片段表无效');
      var pcdStart = pieceStart + (count + 1) * 4, text = '';
      for (var i = 0; i < count && text.length < MAX_RESULT_CHARS; i++) {
        var cp0 = u32le(table, pieceStart + i * 4), cp1 = u32le(table, pieceStart + (i + 1) * 4);
        if (cp0 >= ccpText) break;
        cp1 = Math.min(cp1, ccpText);
        var fcRaw = u32le(table, pcdStart + i * 8 + 2);
        var compressed = !!(fcRaw & 0x40000000), fc = fcRaw & 0x3fffffff;
        if (compressed) fc = Math.floor(fc / 2);
        var chars = Math.min(Math.max(0, cp1 - cp0), MAX_RESULT_CHARS - text.length);
        var byteLen = chars * (compressed ? 1 : 2);
        ensure(fc + byteLen <= word.length, 'corrupt', 'DOC 文字片段越界');
        text += decode(word.subarray(fc, fc + byteLen), compressed ? wordEncoding(word) : 'utf-16le');
      }
      return cleanWordText(text);
    }
    var fcMin = u32le(word, 0x18), unicode = !!(flags & 0x1000);
    var length = Math.min(ccpText, MAX_RESULT_CHARS) * (unicode ? 2 : 1);
    ensure(fcMin + length <= word.length, 'corrupt', 'DOC 缺少可读片段表');
    return cleanWordText(decode(word.subarray(fcMin, fcMin + length), unicode ? 'utf-16le' : wordEncoding(word)));
  }

  function parseDocBytes(bytes, fileName) {
    ensure(isOle(bytes), 'corrupt', 'DOC 不是有效的 Word 97-2003 文件');
    var cfb = cfbRead(bytes);
    assertNoEncryptedOfficeCfb(cfb);
    var word = entryBytes(cfbFind(cfb, 'WordDocument'));
    ensure(word, 'corrupt', 'DOC 缺少 WordDocument 数据流');
    var flags = word.length > 0x0b ? u16le(word, 0x0a) : 0;
    if (flags & 0x0100 || flags & 0x8000) fail('encrypted', 'DOC 已加密/受密码保护');
    var table = entryBytes(cfbFind(cfb, (flags & 0x0200) ? '1Table' : '0Table'));
    ensure(table, 'corrupt', 'DOC 缺少片段表');
    var text = extractDocText(word, table);
    var body = sanitizeHtml(semanticPlainText(text));
    ensure(body && text.trim(), 'empty', 'DOC 中没有可提取正文');
    return { title: stemOf(fileName), body: trimResult(body), kind: 'legacy-doc', format: 'DOC' };
  }

  function inspectMobi(bytes) {
    ensure(bytes.length >= 86, 'corrupt', 'MOBI/AZW 文件过短');
    var recordCount = u16be(bytes, 76);
    ensure(recordCount > 0 && 78 + recordCount * 8 <= bytes.length, 'corrupt', 'MOBI/AZW 记录表损坏');
    var first = u32be(bytes, 78);
    ensure(first + 40 <= bytes.length && decode(bytes.subarray(first + 16, first + 20), 'windows-1252') === 'MOBI', 'corrupt', '不是受支持的 MOBI/AZW 容器');
    if (u16be(bytes, first + 12) !== 0) fail('drm', 'MOBI/AZW 已加密或含 Kindle DRM，已拒绝解析');
    return { version: u32be(bytes, first + 36), firstRecord: first };
  }

  function blobToDataUrl(url, budget) {
    if (!/^blob:/i.test(url || '')) return Promise.resolve(url);
    return fetch(url).then(function (response) { return response.blob(); }).then(function (blob) {
      if (!/^image\/(?:png|jpe?g|gif|webp)$/i.test(blob.type || '') || blob.size > MAX_INLINE_IMAGE_BYTES || budget.used + blob.size > MAX_INLINE_IMAGES_TOTAL) return '';
      budget.used += blob.size;
      return new Promise(function (resolve) {
        var reader = new FileReader();
        reader.onload = function () { resolve(String(reader.result || '')); };
        reader.onerror = function () { resolve(''); };
        reader.readAsDataURL(blob);
      });
    }).catch(function () { return ''; });
  }

  function inlineBlobImages(html, budget) {
    var doc = new DOMParser().parseFromString('<div id="r">' + String(html || '') + '</div>', 'text/html');
    var holder = doc.getElementById('r');
    if (!holder) return Promise.resolve('');
    var images = Array.prototype.slice.call(holder.querySelectorAll('img[src^="blob:"]'));
    return Promise.all(images.map(function (img) {
      return blobToDataUrl(img.getAttribute('src'), budget).then(function (url) {
        if (url) img.setAttribute('src', url); else img.removeAttribute('src');
      });
    })).then(function () { return holder.innerHTML; });
  }

  function loadMobiChapter(book, chapter) {
    try {
      return book.loadChapter(chapter.id);
    } catch (error) {
      // 部分合法 KF8 章节省略独立的 <head>/<body> 包装。上游解析器的
      // replace() 会假定二者必定存在并抛错；loadText() 已完成 SKEL/FRAG
      // 重组，可直接交给本文件的严格白名单清洗器提取语义正文。
      if (typeof book.loadText === 'function') {
        try {
          var raw = book.loadText(chapter);
          if (raw) return { html: raw, css: [] };
        } catch (_) {}
      }
      return null;
    }
  }

  function parseMobiBytes(bytes, fileName) {
    ensure(root.MoTouMobiParser, 'component', 'MOBI/AZW 组件未加载');
    var info = inspectMobi(bytes), ext = extensionOf(fileName);
    var preferKf8 = ext === 'azw3' || info.version >= 8;
    function init(kf8) {
      return (kf8 ? root.MoTouMobiParser.initKf8File : root.MoTouMobiParser.initMobiFile)(bytes);
    }
    var bookPromise = init(preferKf8).catch(function (firstError) {
      if (ext === 'azw3') throw firstError;
      return init(!preferKf8);
    });
    return bookPromise.then(function (book) {
      var metadata = book.getMetadata ? book.getMetadata() : {};
      var spine = book.getSpine ? book.getSpine() : [];
      ensure(spine && spine.length, 'empty', 'MOBI/AZW 书脊中没有可读章节');
      var budget = { used: 0 }, output = createHtmlBudget(), chain = Promise.resolve();
      spine.slice(0, 600).forEach(function (chapter, index) {
        chain = chain.then(function () {
          if (output.truncated) return;
          var loaded = loadMobiChapter(book, chapter);
          if (!loaded || !loaded.html) return;
          return inlineBlobImages(loaded.html, budget).then(function (inlined) {
            var body = sanitizeHtml(inlined);
            if (!body || !body.replace(/<[^>]+>/g, '').trim()) return;
            var hasHeading = /^\s*<h[1-4][\s>]/i.test(body);
            appendHtmlBudget(output, '<section>' + (hasHeading ? '' : '<h2>第 ' + (index + 1) + ' 章</h2>') + body + '</section>', '<hr>');
          });
        });
      });
      return chain.then(function () {
        if (book.destroy) book.destroy();
        if (spine.length > 600) output.truncated = true;
        ensure(output.parts.length, 'empty', 'MOBI/AZW 中没有可读正文');
        return {
          title: (metadata && metadata.title) || stemOf(fileName),
          body: finishHtmlBudget(output), kind: 'ebook',
          format: preferKf8 ? 'AZW3/KF8' : 'MOBI'
        };
      });
    }).catch(function (error) {
      if (error instanceof ImportError) throw error;
      if (/encrypt|drm|password/i.test(String(error && error.message))) fail('drm', 'MOBI/AZW 已加密或含 DRM');
      fail('corrupt', (preferKf8 ? 'AZW3/KF8' : 'MOBI') + '解析失败：仅支持无 DRM 的 PalmDOC/MOBI/KF8');
    });
  }

  function importFile(file) {
    var ext = extensionOf(file), type = String((file && file.type) || '').toLowerCase();
    if (ext === 'md' || ext === 'markdown' || type === 'text/markdown' || type === 'application/markdown' ||
        type === 'text/x-markdown' || type === 'text/md') return parseMarkdownFile(file);
    if (ext === 'docx' || type === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
      return parseDocxFile(file);
    }
    if (ext === 'txt' || type.indexOf('text/') === 0) return parseTextFile(file);
    if (ext === 'epub' || type === 'application/epub+zip') return parseEpubFile(file);
    if (/^(?:mobi|azw|azw3)$/.test(ext) || type === 'application/x-mobipocket-ebook' ||
        type === 'application/x-mobi8-ebook' || type === 'application/vnd.amazon.ebook') {
      return readFileBytes(file).then(function (bytes) { return parseMobiBytes(bytes, file.name); });
    }
    if (ext === 'pptx' || type === 'application/vnd.openxmlformats-officedocument.presentationml.presentation') {
      return readFileBytes(file).then(function (bytes) { return parsePptxBytes(bytes, file.name); });
    }
    if (ext === 'ppt' || type === 'application/vnd.ms-powerpoint') {
      return readFileBytes(file).then(function (bytes) { return parsePptBytes(bytes, file.name); });
    }
    if (/^(?:xls|xlsx)$/.test(ext) || type === 'application/vnd.ms-excel' || type === 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') {
      return readFileBytes(file).then(function (bytes) { return parseSpreadsheetBytes(bytes, file.name); });
    }
    if (ext === 'doc' || type === 'application/msword') {
      return readFileBytes(file).then(function (bytes) { return parseDocBytes(bytes, file.name); });
    }
    return Promise.reject(new ImportError('unsupported', '暂不支持该文档格式'));
  }

  root.MoTouDocumentImport = {
    ImportError: ImportError,
    extensionOf: extensionOf,
    formatLabel: formatLabel,
    isReadableFile: isReadableFile,
    sanitizeHtml: sanitizeHtml,
    finalizeHtml: finalizeHtml,
    readFileBytes: readFileBytes,
    importFile: importFile,
    markdownDocument: markdownDocument,
    // 仅供自动化验证调用，对外 UI 统一走 importFile。
    _test: {
      parseEpubBytes: parseEpubBytes,
      parsePptxBytes: parsePptxBytes,
      parsePptBytes: parsePptBytes,
      fallbackPptText: fallbackPptText,
      pptContainsCryptRecord: pptContainsCryptRecord,
      parseSpreadsheetBytes: parseSpreadsheetBytes,
      parseDocBytes: parseDocBytes,
      parseMobiBytes: parseMobiBytes,
      inspectMobi: inspectMobi,
      unzipSafe: unzipSafe,
      preflightZipCentralDirectory: preflightZipCentralDirectory,
      safeImageSrc: safeImageSrc,
      isAllowedEpubFontObfuscation: isAllowedEpubFontObfuscation,
      hasEpubRightsProtection: hasEpubRightsProtection,
      trimResult: trimResult,
      clampDecodedSheetRange: clampDecodedSheetRange,
      spreadsheetRangePlan: spreadsheetRangePlan,
      takeSpreadsheetRows: takeSpreadsheetRows,
      extractSpreadsheetGrid: extractSpreadsheetGrid,
      limits: {
        maxFileBytes: MAX_FILE_BYTES,
        maxUnzippedBytes: MAX_UNZIPPED_BYTES,
        maxZipEntries: MAX_ZIP_ENTRIES,
        maxZipEntryUnzippedBytes: MAX_ZIP_ENTRY_UNZIPPED_BYTES,
        maxPptRecords: MAX_PPT_RECORDS,
        maxResultChars: MAX_RESULT_CHARS,
        maxSpreadsheetRows: MAX_SPREADSHEET_ROWS,
        maxSpreadsheetColumns: MAX_SPREADSHEET_COLUMNS,
        maxSpreadsheetCells: MAX_SPREADSHEET_CELLS
      }
    }
  };
})(window);
