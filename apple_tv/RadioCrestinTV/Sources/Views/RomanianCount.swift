/// A count with its noun, as Romanian says it: "1 ascultător",
/// "12 ascultători", "20 de ascultători". Romanian puts "de" after numbers
/// from 20 up whose last two digits are not 01–19.
enum RomanianCount {
    static func phrase(_ count: Int, one: String, many: String) -> String {
        if count == 1 { return "1 \(one)" }
        let lastTwo = count % 100
        let takesDe = count >= 20 && (lastTwo == 0 || lastTwo >= 20)
        return takesDe ? "\(count) de \(many)" : "\(count) \(many)"
    }
}
