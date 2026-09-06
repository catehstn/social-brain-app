import Testing
import Foundation
@testable import SocialBrain

@Suite("O'Reilly Importer Tests")
struct OReillyImporterTests {

    private let importer = OReillyImporter()

    // MARK: - EML / MIME

    @Test("Parses payment fields from a multipart EML")
    func parseEML() throws {
        let eml = """
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="testboundary"

        --testboundary
        Content-Type: text/plain; charset=UTF-8

        Payment Remittance Advice

        --testboundary
        Content-Type: text/html; charset=UTF-8

        <html><body>
        <table>
        <tr><td>Payment Date</td><td>Mar 31, 2026</td></tr>
        <tr><td>Payment Currency</td><td>USD</td></tr>
        <tr><td>Payment Amount</td><td>77.96</td></tr>
        <tr><td>Paper Document Number</td><td>211196</td></tr>
        </table>
        <table>
        <tr>
          <td>AP-1416088</td><td>30-Mar-26</td><td>ROYALTY STATEMENT</td>
          <td>77.96</td><td>USD</td><td>.00</td><td>77.96</td>
        </tr>
        </table>
        </body></html>

        --testboundary--
        """
        let data = try #require(eml.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.platform == .oreilly)
        #expect(result.doubleMetric("payment_amount") == 77.96)
        #expect(result.stringMetric("payment_currency") == "USD")
        #expect(result.stringMetric("payment_date") == "2026-03-31")
        #expect(result.stringMetric("doc_number") == "211196")
        #expect(result.intMetric("line_item_count") == 1)
    }

    @Test("Parses multiple royalty line items")
    func multipleLineItems() throws {
        let eml = """
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="b"

        --b
        Content-Type: text/html; charset=UTF-8

        <html><body>
        <td>Payment Date</td><td>Jan 31, 2026</td>
        <td>Payment Currency</td><td>USD</td>
        <td>Payment Amount</td><td>150.00</td>
        <td>AP-1000001</td><td>30-Jan-26</td><td>ROYALTY STATEMENT</td><td>75.00</td><td>USD</td><td>.00</td><td>75.00</td>
        <td>AP-1000002</td><td>30-Jan-26</td><td>ROYALTY STATEMENT</td><td>75.00</td><td>USD</td><td>.00</td><td>75.00</td>
        </body></html>

        --b--
        """
        let data = try #require(eml.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.doubleMetric("payment_amount") == 150.00)
        #expect(result.intMetric("line_item_count") == 2)
    }

    @Test("Handles style block in HTML (tokens not leaked)")
    func styleBlockNotTokenised() throws {
        let eml = """
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="b"

        --b
        Content-Type: text/html; charset=UTF-8

        <html>
        <head><style>body { font-family: Arial; } .Payment { color: red; }</style></head>
        <body>
        <td>Payment Date</td><td>Feb 28, 2026</td>
        <td>Payment Currency</td><td>USD</td>
        <td>Payment Amount</td><td>50.00</td>
        </body></html>

        --b--
        """
        let data = try #require(eml.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.doubleMetric("payment_amount") == 50.00)
        #expect(result.stringMetric("payment_date") == "2026-02-28")
    }

    @Test("Defaults currency to USD when absent")
    func missingCurrencyDefaultsToUSD() throws {
        let eml = """
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="b"

        --b
        Content-Type: text/html; charset=UTF-8

        <td>Payment Date</td><td>Jun 30, 2025</td>
        <td>Payment Amount</td><td>42.00</td>

        --b--
        """
        let data = try #require(eml.data(using: .utf8))
        let result = try importer.parse(data: data)
        #expect(result.stringMetric("payment_currency") == "USD")
    }

    // MARK: - Error cases

    @Test("Throws on empty file")
    func emptyFileThrows() {
        let data = Data()
        #expect(throws: (any Error).self) {
            try importer.parse(data: data)
        }
    }

    @Test("Throws when required payment fields are absent")
    func missingFieldsThrows() {
        let txt = "Hello world\nThis is not an O'Reilly email.\n"
        let data = txt.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try importer.parse(data: data)
        }
    }
}
