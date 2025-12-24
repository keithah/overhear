import XCTest
@testable import Overhear

final class PromptTemplateTests: XCTestCase {
    func testDefaultTemplateExists() {
        XCTAssertNotNil(PromptTemplate.defaultTemplate)
        XCTAssertEqual(PromptTemplate.defaultTemplate.id, "default")
    }

    func testAllTemplatesIncludesDefault() {
        let allTemplates = PromptTemplate.allTemplates
        XCTAssertFalse(allTemplates.isEmpty)
        XCTAssertTrue(allTemplates.contains(where: { $0.id == "default" }))
    }

    func testTemplateHasRequiredFields() {
        let template = PromptTemplate.defaultTemplate
        XCTAssertFalse(template.id.isEmpty)
        XCTAssertFalse(template.title.isEmpty)
        XCTAssertFalse(template.body.isEmpty)
    }

    func testTemplateIDsAreUnique() {
        let templates = PromptTemplate.allTemplates
        let ids = templates.map(\.id)
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count, "Template IDs should be unique")
    }

    func testTemplateBodyIsDescriptive() {
        let template = PromptTemplate.defaultTemplate
        // Default template should describe summarization task
        XCTAssertTrue(
            template.body.lowercased().contains("summarize") ||
            template.body.lowercased().contains("summary"),
            "Default template body should describe summarization"
        )
    }
}
