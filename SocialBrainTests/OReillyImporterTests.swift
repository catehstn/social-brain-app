import Testing
import Foundation
@testable import SocialBrain

@Suite("O'Reilly Importer Tests")
struct OReillyImporterTests {

    private let importer = OReillyImporter()

    // MARK: - Tabular format

    @Test("Parses tabular report with page views and unique users")
    func tabularReport() throws {
        let txt = """
        O'Reilly Learning Platform - Monthly Report - February 2026

        Title                           Page Views   Unique Users   Completions
        Swift in Depth                  4521         1203           87
        Advanced SwiftUI Patterns       2340         810            45
        Concurrency in Swift            1890         654            32
        """
        let data = try #require(txt.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.platform == .oreilly)
        #expect(result.intMetric("total_page_views") == 8751)
        #expect(result.intMetric("total_unique_users") == 2667)
        #expect(result.intMetric("total_completions") == 164)
        #expect(result.intMetric("titles_count") == 3)
    }

    @Test("Parses tabular report without completions column")
    func tabularReportNoCompletions() throws {
        let txt = """
        Monthly Report

        Title                   Page Views   Unique Users
        Book One                1000         300
        Book Two                2000         600
        """
        let data = try #require(txt.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("total_page_views") == 3000)
        #expect(result.intMetric("total_unique_users") == 900)
        #expect(result.intMetric("total_completions") == nil)
    }

    @Test("Handles comma-formatted numbers")
    func handlesCommaNumbers() throws {
        let txt = """
        Monthly Report

        Title          Page Views   Unique Users
        Popular Book   12,500       4,200
        """
        let data = try #require(txt.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("total_page_views") == 12500)
        #expect(result.intMetric("total_unique_users") == 4200)
    }

    // MARK: - Key-value format

    @Test("Parses key-value format")
    func keyValueFormat() throws {
        let txt = """
        O'Reilly Monthly Author Report

        Page views: 9,432
        Unique users: 3,105
        Completions: 220
        Titles: 5
        """
        let data = try #require(txt.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.intMetric("total_page_views") == 9432)
        #expect(result.intMetric("total_unique_users") == 3105)
        #expect(result.intMetric("total_completions") == 220)
        #expect(result.intMetric("titles_count") == 5)
    }

    // MARK: - Error cases

    @Test("Throws on empty file")
    func emptyFileThrows() {
        let data = Data()
        #expect(throws: (any Error).self) {
            try importer.parse(data: data)
        }
    }

    @Test("Throws on unrecognised format")
    func unrecognisedFormatThrows() {
        let txt = "Hello world\nThis is not a report\n"
        let data = txt.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try importer.parse(data: data)
        }
    }
}
