package com.motou.sender

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Optional compatibility checks against real files produced by common desktop tools and
 * published DRM-free Kindle books. The fixtures are intentionally not committed; point
 * MOTOU_FORMAT_FIXTURE_DIR at a directory containing the named files to enable these tests.
 */
class ReadableDocumentsRealFixturesTest {
    @Test fun importsRealMarkdown() = assertFixture("format-sample.md", "墨投格式测试")

    @Test fun importsRealEpub() = assertFixture("format-sample.epub", "墨投格式测试")

    @Test fun importsRealDocx() = assertFixture("format-sample.docx", "墨投格式测试")

    @Test fun importsRealLegacyDoc() = assertFixture("format-sample.doc", "墨投格式测试")

    @Test fun importsRealPptx() = assertFixture("format-sample.pptx", "墨投格式测试")

    @Test fun importsRealLegacyPpt() = assertFixture("format-sample.ppt", "墨投格式测试")

    @Test fun importsRealXlsx() = assertFixture("sheet-sample.xlsx", "名称")

    @Test fun importsRealLegacyXls() = assertFixture("sheet-sample.xls", "名称")

    @Test fun importsPublishedDrmFreeMobi() {
        assertFixture(
            "alice-older-kindle.mobi",
            "Rabbit-Hole",
            minHtmlLength = 50_000,
            expectedTitle = "Alice's Adventures in Wonderland",
        )
    }

    @Test fun importsPublishedDrmFreeKf8Azw3() {
        assertFixture(
            "alice-kf8.azw3",
            "Rabbit-Hole",
            minHtmlLength = 50_000,
            expectedTitle = "Alice's Adventures in Wonderland",
        )
    }

    private fun assertFixture(
        name: String,
        expectedText: String,
        minHtmlLength: Int = 1,
        expectedTitle: String? = null,
    ) {
        val directory = System.getenv("MOTOU_FORMAT_FIXTURE_DIR")?.let(::File)
        assumeTrue(
            "Set MOTOU_FORMAT_FIXTURE_DIR to enable real-format compatibility tests",
            directory?.isDirectory == true,
        )
        val fixture = File(requireNotNull(directory), name)
        assumeTrue("Fixture is missing: ${fixture.absolutePath}", fixture.isFile)

        val result = ReadableDocuments.render(fixture.readBytes(), fixture.name, null, null)
        assertTrue(
            "$name should contain '$expectedText' but produced ${result.html.take(240)}",
            result.html.contains(expectedText, ignoreCase = true),
        )
        assertTrue(
            "$name should yield substantial readable content (${result.html.length} characters)",
            result.html.length >= minHtmlLength,
        )
        if (expectedTitle != null) {
            assertTrue("$name should use its embedded title: ${result.title}", result.title.contains(expectedTitle))
        }
        assertFalse("$name must not retain scripts", result.html.contains("<script", ignoreCase = true))
        assertFalse("$name must not retain iframes", result.html.contains("<iframe", ignoreCase = true))
    }
}
