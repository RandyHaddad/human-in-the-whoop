#if canImport(XCTest)
import XCTest

final class NamespaceTests: XCTestCase {}
#else
import Testing

@Suite struct NamespaceTests {}
#endif
