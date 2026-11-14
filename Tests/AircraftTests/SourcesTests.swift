import XCTest
@testable import aircraft

final class SourcesTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00Z")!

    private func articlePage() -> SourceCapture.Page {
        SourceCapture.Page(title: "Ignored", language: "ru", meta: [
            "citation_title": ["Глубокое обучение в браузере"],
            "citation_author": ["Иванов, Иван Петрович", "Anna Smith"],
            "citation_journal_title": ["Вопросы информатики"],
            "citation_publication_date": ["2023/05/14"],
            "citation_volume": ["12"],
            "citation_issue": ["3"],
            "citation_firstpage": ["45"],
            "citation_lastpage": ["67"],
            "citation_doi": ["doi:10.1234/abc.2023.5"],
            "citation_pdf_url": ["/files/paper.pdf"],
            "citation_keywords": ["WebKit; браузеры"]
        ])
    }

    func testScholarlyMetadataBecomesJournalArticle() {
        let item = SourceCapture.makeItem(articlePage(), url: URL(string: "https://journal.example/a/1")!, now: date)
        XCTAssertEqual(item.type, .article)
        XCTAssertEqual(item.title, "Глубокое обучение в браузере")
        XCTAssertEqual(item.creators, [SourceCreator(lastName: "Иванов", firstName: "Иван Петрович"),
                                       SourceCreator(lastName: "Smith", firstName: "Anna")])
        XCTAssertEqual(item.container, "Вопросы информатики")
        XCTAssertEqual(item.year, "2023")
        XCTAssertEqual(item.pages, "45–67")
        XCTAssertEqual(item.doi, "10.1234/abc.2023.5")
        XCTAssertEqual(item.pdfURL, "https://journal.example/files/paper.pdf")
        XCTAssertEqual(item.tags, ["WebKit", "браузеры"])
    }

    func testPlainPageBecomesWebpage() {
        let page = SourceCapture.Page(title: "Новости", meta: ["og:site_name": ["Пример"]])
        let item = SourceCapture.makeItem(page, url: URL(string: "https://example.com/news")!, now: date)
        XCTAssertEqual(item.type, .webpage)
        XCTAssertEqual(item.title, "Новости")
        XCTAssertEqual(item.container, "Пример")
    }

    func testDOIFromLink() {
        XCTAssertEqual(SourceCapture.extractDOI("https://doi.org/10.1000/xyz123."), "10.1000/xyz123")
        XCTAssertNil(SourceCapture.extractDOI("https://example.com"))
    }

    func testInitials() {
        XCTAssertEqual(SourceCreator(parsing: "Иванов, Иван Петрович").initials, "И. П.")
        XCTAssertEqual(SourceCreator(parsing: "Jean-Paul Sartre").initials, "J.-P.")
    }

    func testGostAndApa() {
        let item = SourceCapture.makeItem(articlePage(), url: URL(string: "https://journal.example/a/1")!, now: date)
        XCTAssertEqual(Citation.gost(item, accessed: date),
                       "Иванов, И. П. Глубокое обучение в браузере / И. П. Иванов, A. Smith // Вопросы информатики. — 2023. — Т. 12, № 3. — С. 45–67. — DOI 10.1234/abc.2023.5.")
        XCTAssertEqual(Citation.apa(item),
                       "Иванов, И. П., & Smith, A. (2023). Глубокое обучение в браузере. Вопросы информатики, 12(3), 45–67. https://doi.org/10.1234/abc.2023.5")
    }

    func testBibtexAndRis() {
        let item = SourceCapture.makeItem(articlePage(), url: URL(string: "https://journal.example/a/1")!, now: date)
        let bib = Citation.bibtex([item, item])
        XCTAssertTrue(bib.contains("@article{"))
        XCTAssertTrue(bib.contains("author = {Иванов, Иван Петрович and Smith, Anna}"))
        XCTAssertTrue(bib.contains("pages = {45--67}"))
        let keys = bib.components(separatedBy: "\n").filter { $0.hasPrefix("@article{") }
        XCTAssertEqual(Set(keys).count, 2, "Повторный ключ получает суффикс")
        let ris = Citation.ris([item])
        XCTAssertTrue(ris.hasPrefix("TY  - JOUR"))
        XCTAssertTrue(ris.contains("SP  - 45"))
        XCTAssertTrue(ris.contains("EP  - 67"))
        XCTAssertTrue(ris.hasSuffix("ER  - \n"))
    }
}
