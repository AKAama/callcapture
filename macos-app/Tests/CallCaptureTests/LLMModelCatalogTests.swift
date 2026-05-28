import Foundation
import Testing
@testable import CallCapture

@Suite("LLMModelCatalog")
struct LLMModelCatalogTests {
    @Test("catalog contains the worker's default slug")
    func defaultPresent() {
        let opt = LLMModelCatalog.option(for: LLMModelCatalog.defaultSlug)
        #expect(opt.isCustom == false)
        #expect(opt.slug == LLMModelCatalog.defaultSlug)
    }

    @Test("slugs are unique within the curated list")
    func uniqueSlugs() {
        let slugs = LLMModelCatalog.curated.filter { !$0.isCustom }.map(\.slug)
        #expect(slugs.count == Set(slugs).count)
    }

    @Test("custom sentinel is last and round-trips an unknown slug")
    func customFallback() {
        #expect(LLMModelCatalog.curated.last?.isCustom == true)
        let opt = LLMModelCatalog.option(for: "experimental/never-shipped-model")
        #expect(opt.isCustom == true)
    }

    @Test("display names are non-empty")
    func displayNames() {
        for opt in LLMModelCatalog.curated {
            #expect(!opt.displayName.isEmpty)
        }
    }
}
