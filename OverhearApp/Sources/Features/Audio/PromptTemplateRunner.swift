import Foundation
import os.log

/// Executes saved prompt templates against transcripts/notes using the shared MLX pipeline when available.
actor PromptTemplateRunner {
    static let shared = PromptTemplateRunner(pipeline: LocalLLMPipeline.shared)

    private let pipeline: LocalLLMPipeline
    private let logger = Logger(subsystem: "com.overhear.app", category: "PromptTemplateRunner")

    init(pipeline: LocalLLMPipeline) {
        self.pipeline = pipeline
    }

    func run(template: PromptTemplate, transcript: String, notes: String?) async -> String {
        await pipeline.runTemplate(template, transcript: transcript, notes: notes)
    }
}
