import Foundation
import Testing
@testable import MacSizeCore

struct VolumeUsageTests {
    @Test func splitsPurgeableFromUsed() {
        // Figures from a real 1 TB Mac: Settings showed 648 GB used, Disk Utility ~944 GB.
        let usage = VolumeUsage(total: 994_610_155_520, free: 50_584_608_768, available: 346_377_321_398)
        #expect(usage.used == 648_232_834_122)
        #expect(usage.inUse == 944_025_546_752)
        #expect(usage.purgeable == 295_792_712_630)
        #expect(usage.used + usage.purgeable + usage.free == usage.total)
    }

    @Test func clampsInconsistentReadings() {
        // Available below free (no purgeable accounting) and above total.
        let low = VolumeUsage(total: 100, free: 40, available: 10)
        #expect(low.available == 40)
        #expect(low.purgeable == 0)
        let high = VolumeUsage(total: 100, free: 40, available: 500)
        #expect(high.available == 100)
        #expect(high.used == 0)
    }

    @Test func readsTheBootVolume() throws {
        let usage = try #require(VolumeUsage.read(for: URL(fileURLWithPath: "/")))
        #expect(usage.total > 0)
        #expect(usage.free <= usage.available)
        #expect(usage.available <= usage.total)
    }
}
