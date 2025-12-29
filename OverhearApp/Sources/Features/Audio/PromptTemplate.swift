import Foundation

struct PromptTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let body: String

    static let allTemplates: [PromptTemplate] = [
        PromptTemplate(id: "default", title: "Default", body: "Summarize and extract highlights and action items."),
        PromptTemplate(id: "action-heavy", title: "Action-heavy", body: "Focus on action items with owners and next steps."),
        PromptTemplate(id: "brief", title: "Brief", body: "Provide a very short summary and top 3 bullets."),
    ]

    static var defaultTemplate: PromptTemplate { allTemplates[0] }
}
