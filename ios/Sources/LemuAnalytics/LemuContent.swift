import Foundation

/// One line of an order or cart, sent in `contents` (Meta's format).
@objc(LemuContent)
public final class LemuContent: NSObject {
    /// Product id or SKU.
    @objc public let id: String
    @objc public let quantity: Int
    /// Price of one item, in major units (1499.5 for Rs 1,499.50).
    public let itemPrice: Double?
    public let title: String?
    public let brand: String?
    public let category: String?

    public init(
        id: String,
        quantity: Int = 1,
        itemPrice: Double? = nil,
        title: String? = nil,
        brand: String? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.quantity = quantity
        self.itemPrice = itemPrice
        self.title = title
        self.brand = brand
        self.category = category
        super.init()
    }

    /// Objective-C: `[[LemuContent alloc] initWithId:@"SKU1" quantity:1 itemPrice:@1499.5 title:nil]`.
    @objc(initWithId:quantity:itemPrice:title:)
    public convenience init(objcId id: String, quantity: Int, itemPriceNumber: NSNumber?, title: String?) {
        self.init(id: id, quantity: quantity, itemPrice: itemPriceNumber?.doubleValue, title: title)
    }

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "quantity": .int(Int64(quantity))]
        if let price = itemPrice, price.isFinite { object["item_price"] = .double(price) }
        if let title = title { object["title"] = .string(title) }
        if let brand = brand { object["brand"] = .string(brand) }
        if let category = category { object["category"] = .string(category) }
        return .object(object)
    }
}
