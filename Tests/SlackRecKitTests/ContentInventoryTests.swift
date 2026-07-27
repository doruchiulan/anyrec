import Testing

@testable import SlackRecKit

@Suite("ContentInventory")
struct ContentInventoryTests {
    @Test("keeps the windows apps actually draw")
    func keepsAppWindows() {
        #expect(ContentInventory.isUserFacing(layer: 0, width: 1285, height: 1289))
        #expect(ContentInventory.isUserFacing(layer: 0, width: 642, height: 170))
    }

    @Test("drops the furniture macOS shares alongside them")
    func dropsSystemFurniture() {
        #expect(!ContentInventory.isUserFacing(layer: -2_147_483_626, width: 5120, height: 2160))
        #expect(!ContentInventory.isUserFacing(layer: -2_147_483_601, width: 720, height: 360))
        #expect(!ContentInventory.isUserFacing(layer: 20, width: 2056, height: 1329))
        #expect(!ContentInventory.isUserFacing(layer: 24, width: 5120, height: 30))
        #expect(!ContentInventory.isUserFacing(layer: 25, width: 166, height: 30))
        #expect(!ContentInventory.isUserFacing(layer: 2_147_483_630, width: 28, height: 28))
    }

    @Test("drops popups too small to be worth recording")
    func dropsPopups() {
        #expect(!ContentInventory.isUserFacing(layer: 0, width: 403, height: 84))
        #expect(!ContentInventory.isUserFacing(layer: 0, width: 66, height: 20))
    }
}
