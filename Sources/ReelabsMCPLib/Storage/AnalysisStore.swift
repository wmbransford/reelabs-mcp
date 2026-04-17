import Foundation

/// Markdown + JSON sidecar storage for visual analyses.
/// - `{dataRoot}/projects/{project}/{source}.analysis.md`
/// - `{dataRoot}/projects/{project}/{source}.scenes.json`
package struct AnalysisStore: Sendable {
    let paths: DataPaths

    package init(paths: DataPaths) {
        self.paths = paths
    }

    package func saveRecord(project: String, source: String, record: AnalysisRecord) throws -> AnalysisRecord {
        try FileManager.default.createDirectory(
            at: paths.projectDir(project),
            withIntermediateDirectories: true
        )
        let url = paths.analysisMarkdown(project: project, source: source)
        let body = "# Visual Analysis: \(source)\n"
        let file = MarkdownFile(frontMatter: record, body: body)
        try MarkdownStore.write(file, to: url)
        return record
    }

    package func getRecord(project: String, source: String) throws -> AnalysisRecord? {
        let url = paths.analysisMarkdown(project: project, source: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try MarkdownStore.read(at: url, as: AnalysisRecord.self).frontMatter
    }

    package func storeScenes(project: String, source: String, scenes: [SceneRecord]) throws {
        let scenesURL = paths.analysisScenes(project: project, source: source)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(scenes)
        try MarkdownStore.writeData(data, to: scenesURL)

        // Update record status + sceneCount
        if var record = try getRecord(project: project, source: source) {
            record.status = "analyzed"
            record.sceneCount = scenes.count
            _ = try saveRecord(project: project, source: source, record: record)
        }
    }

    package func getScenes(project: String, source: String) throws -> [SceneRecord] {
        let scenesURL = paths.analysisScenes(project: project, source: source)
        guard FileManager.default.fileExists(atPath: scenesURL.path) else { return [] }
        let data = try Data(contentsOf: scenesURL)
        return try JSONDecoder().decode([SceneRecord].self, from: data)
    }
}
