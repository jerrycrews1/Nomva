import Foundation

struct BarcodeIdentity: Equatable, Sendable {
    let digits: String
    let gtin14: String

    init?(_ value: String, isUPCE: Bool = false) {
        let clean = value.filter { $0 != " " && $0 != "-" }
        guard clean.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let code: String
        if isUPCE {
            guard let expanded = Self.expandUPCE(clean) else { return nil }
            code = expanded
        } else { code = clean }
        guard [8, 12, 13, 14].contains(code.count), code.contains(where: { $0 != "0" }) else { return nil }
        let numbers = code.compactMap(\.wholeNumberValue)
        let sum = numbers.dropLast().reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 3 : 1) }
        guard (10 - sum % 10) % 10 == numbers.last else { return nil }
        digits = code
        gtin14 = String(repeating: "0", count: 14 - code.count) + code
    }

    var aliases: [String] {
        let trimmed = String(gtin14.drop(while: { $0 == "0" }))
        var values = [digits, gtin14, trimmed]
        for length in [8, 12, 13] where trimmed.count <= length {
            values.append(String(repeating: "0", count: length - trimmed.count) + trimmed)
        }
        return Array(Set(values)).sorted()
    }

    var providerCode: String {
        if digits.count == 8 { return digits }
        return gtin14.hasPrefix("0") ? String(gtin14.suffix(13)) : gtin14
    }

    static func matches(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        if let a = Self(lhs), let b = Self(rhs) { return a.gtin14 == b.gtin14 }
        return !lhs.isEmpty && lhs == rhs
    }

    private static func expandUPCE(_ value: String) -> String? {
        let d = value.map(String.init)
        guard d.count == 8, d[0] == "0" || d[0] == "1" else { return nil }
        let payload: String
        switch d[6] {
        case "0", "1", "2": payload = d[1] + d[2] + d[6] + "0000" + d[3] + d[4] + d[5]
        case "3": payload = d[1] + d[2] + d[3] + "00000" + d[4] + d[5]
        case "4": payload = d[1] + d[2] + d[3] + d[4] + "00000" + d[5]
        default: payload = d[1] + d[2] + d[3] + d[4] + d[5] + "0000" + d[6]
        }
        return d[0] + payload + d[7]
    }
}

enum BarcodeLookupSource: Sendable { case bundledDatabase, openFoodFacts, cache }
enum BarcodeLookupOutcome: Sendable {
    case found(FoodItem, BarcodeLookupSource)
    case notFound, unavailable, invalidBarcode, incompleteNutrition
}

enum OpenFoodFactsDecoder {
    static func decode(_ data: Data, identity: BarcodeIdentity) throws -> BarcodeLookupOutcome {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unavailable }
        guard (root["status"] as? Int) == 1 else {
            return (root["status"] as? Int) == 0 ? .notFound : .unavailable
        }
        guard let product = root["product"] as? [String: Any],
              let code = (product["code"] ?? root["code"]) as? String,
              BarcodeIdentity.matches(code, identity.digits) else { return .unavailable }
        let name = ((product["product_name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let n = product["nutriments"] as? [String: Any] else { return .incompleteNutrition }
        func number(_ value: Any?) -> Double? {
            let result: Double?
            if let v = value as? NSNumber { result = v.doubleValue }
            else if let v = value as? String { result = Double(v) }
            else { result = nil }
            return result.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        // OFF _100g fields are already normalized (g for mass, kcal/kJ for energy),
        // regardless of the original label's *_unit. Liquids are per 100 ml.
        let desc = product["serving_size"] as? String ?? ""
        let unit = (product["serving_quantity_unit"] as? String ?? "").lowercased()
        let volume = unit == "ml" || desc.range(of: #"(?i)\b(ml|fl\s*oz|lit(?:er|re)s?)\b"#, options: .regularExpression) != nil
        let gramRange = desc.range(of: #"(?i)\d+(?:\.\d+)?\s*g\b"#, options: .regularExpression)
        let parsedGrams = gramRange.flatMap { Double(desc[$0].lowercased().replacingOccurrences(of: "g", with: "").trimmingCharacters(in: .whitespaces)) }
        let mlRange = desc.range(of: #"(?i)\d+(?:\.\d+)?\s*ml\b"#, options: .regularExpression)
        let parsedML = mlRange.flatMap { Double(desc[$0].lowercased().replacingOccurrences(of: "ml", with: "").trimmingCharacters(in: .whitespaces)) }
        let quantity = (unit == "g" || unit == "ml") ? number(product["serving_quantity"]) : (volume ? parsedML : parsedGrams)
        let knownMass = !volume && (unit == "g" || parsedGrams != nil)
        let basisAmount = quantity.flatMap { $0 > 0 && $0 <= 5_000 ? $0 : nil } ?? 100
        let factor = basisAmount / 100
        func nutrient(_ key: String) -> Double? { number(n["\(key)_100g"]).map { $0 * factor } }
        let energy = nutrient("energy-kcal") ?? nutrient("energy-kj").map { $0 / 4.184 } ?? nutrient("energy").map { $0 / 4.184 }
        guard let calories = energy, let protein = nutrient("proteins"),
              let carbs = nutrient("carbohydrates"), let fat = nutrient("fat"),
              calories <= 1_000 * factor, protein <= 100 * factor,
              carbs <= 100 * factor, fat <= 100 * factor else { return .incompleteNutrition }
        let fiber = nutrient("fiber"), sugar = nutrient("sugars")
        let sodium = nutrient("sodium").map { $0 * 1_000 } ?? nutrient("salt").map { $0 / 2.5 * 1_000 }
        let missing = [("fiber", fiber), ("sugar", sugar), ("sodium", sodium)].compactMap { $0.1 == nil ? $0.0 : nil }
        return .found(FoodItem(
            id: -Int(identity.gtin14)!, name: name,
            brand: (product["brands"] as? String)?.split(separator: ",").first.map(String.init),
            source: "open_food_facts_online", servingGrams: knownMass ? basisAmount : nil,
            servingDesc: quantity != nil && !desc.isEmpty ? desc : "\(basisAmount.formatted()) \(volume ? "ml" : knownMass ? "g" : "g or ml")",
            caloriesPerServing: calories, proteinG: protein, carbsG: carbs, fatG: fat,
            fiberG: fiber ?? 0, sugarG: sugar ?? 0, sodiumMg: sodium ?? 0,
            saturatedFatG: nutrient("saturated-fat"), transFatG: nutrient("trans-fat"),
            cholesterolMg: nutrient("cholesterol").map { $0 * 1_000 },
            calciumMg: nutrient("calcium").map { $0 * 1_000 },
            ironMg: nutrient("iron").map { $0 * 1_000 },
            potassiumMg: nutrient("potassium").map { $0 * 1_000 },
            barcode: identity.digits, portionBasis: knownMass ? .grams : .fixedServing,
            servingSource: quantity == nil ? .fallbackRaw : .explicitServing,
            missingNutrients: missing
        ), .openFoodFacts)
    }
}

actor BarcodeLookupService {
    static let shared = BarcodeLookupService()
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private struct CachedProduct: Codable { let food: FoodItem; let fetchedAt: Date }
    private let fetch: Fetch
    private let localLookup: @Sendable (String) async -> FoodItem?
    private let minimumRequestInterval: TimeInterval
    private let cacheURL: URL?
    private var products: [String: CachedProduct] = [:]
    private var misses: [String: Date] = [:]
    private var inFlight: [String: Task<BarcodeLookupOutcome, Never>] = [:]
    private var nextRequest = Date.distantPast
    private var retryAfter = Date.distantPast

    init(cacheURL: URL? = nil, minimumRequestInterval: TimeInterval = 4.1,
         localLookup: @escaping @Sendable (String) async -> FoodItem? = { await DatabaseManager.shared.food(byBarcode: $0) },
         fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.fetch = fetch
        self.localLookup = localLookup
        self.minimumRequestInterval = minimumRequestInterval
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("nomva-barcodes-v1.json")
        if let url = self.cacheURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: CachedProduct].self, from: data) { products = saved }
    }

    func lookup(barcode: String) async -> BarcodeLookupOutcome {
        guard let identity = BarcodeIdentity(barcode) else { return .invalidBarcode }
        if let local = await localLookup(identity.digits) { return .found(local, .bundledDatabase) }
        let key = identity.gtin14
        if let cached = products[key], Date().timeIntervalSince(cached.fetchedAt) < 14 * 86_400 { return .found(cached.food, .cache) }
        if let missed = misses[key], Date().timeIntervalSince(missed) < 600 { return .notFound }
        if let existing = inFlight[key] { return await existing.value }
        guard retryAfter < Date() else { return cachedOrUnavailable(key) }
        // Direct product requests are limited to 15/min/IP. Reserve slots before awaiting.
        let slot = max(Date(), nextRequest)
        nextRequest = slot.addingTimeInterval(minimumRequestInterval)
        guard slot.timeIntervalSinceNow < 10 else { return cachedOrUnavailable(key) }
        let task = Task { await self.lookupOnline(identity, at: slot) }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    private func cachedOrUnavailable(_ key: String) -> BarcodeLookupOutcome {
        products[key].map { .found($0.food, .cache) } ?? .unavailable
    }

    private func lookupOnline(_ identity: BarcodeIdentity, at slot: Date) async -> BarcodeLookupOutcome {
        do {
            if slot > Date() { try await Task.sleep(for: .seconds(slot.timeIntervalSinceNow)) }
            var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(identity.providerCode).json")!
            components.queryItems = [URLQueryItem(name: "fields", value: "code,product_name,brands,serving_size,serving_quantity,serving_quantity_unit,nutriments")]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 10
            request.setValue("Nomva/1.0 (iOS; https://nomva.nerdquad.com)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { return cachedOrUnavailable(identity.gtin14) }
            if http.statusCode == 429 || http.statusCode == 503 {
                retryAfter = Date().addingTimeInterval(max(60, min(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60, 3_600)))
                return cachedOrUnavailable(identity.gtin14)
            }
            guard http.statusCode == 200 || http.statusCode == 404 else { return cachedOrUnavailable(identity.gtin14) }
            let outcome = try OpenFoodFactsDecoder.decode(data, identity: identity)
            switch outcome {
            case .found(let food, _):
                products[identity.gtin14] = CachedProduct(food: food, fetchedAt: .now)
                if products.count > 2_000, let oldest = products.min(by: { $0.value.fetchedAt < $1.value.fetchedAt }) { products.removeValue(forKey: oldest.key) }
                if let cacheURL, let data = try? JSONEncoder().encode(products) { try? data.write(to: cacheURL, options: .atomic) }
            case .notFound: misses[identity.gtin14] = .now
            default: break
            }
            return outcome
        } catch { return cachedOrUnavailable(identity.gtin14) }
    }
}
