import Foundation

public enum ChineseConverter {
    /// Converts Traditional Chinese to Simplified Chinese using system ICU StringTransform
    public static func toSimplified(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        if CFStringTransform(mutable as CFMutableString, nil, "Traditional-Simplified" as CFString, false) {
            return mutable as String
        }
        return text
    }
}
