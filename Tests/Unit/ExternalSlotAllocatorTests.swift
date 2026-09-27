//  ExternalSlotAllocatorTests.swift
//  外部処理（AU / JSFX）の枠番号の割り当て（ETExternalSlotAllocator）。
//
//  鎖の記述子は外部処理を番号で指す。同じインスタンスの番号が動くと、鎖が別の
//  プラグインを鳴らす。上限（ET_EXTERNAL_MAX_PROCESSORS = 8）を超えたら断る。

import XCTest

final class ExternalSlotAllocatorTests: XCTestCase {

    private func full(_ n: Int = 8) -> ETExternalSlotAllocator {
        var a = ETExternalSlotAllocator(capacity: 8)
        for i in 0..<n { _ = a.reserve("i\(i)") }
        return a
    }

    /// 同じ id には同じ番号。何度 reserve しても動かない。
    func testSameIDSameSlot() {
        var a = ETExternalSlotAllocator(capacity: 8)
        let first = a.reserve("au-1")
        _ = a.reserve("jsfx-2")
        XCTAssertEqual(a.reserve("au-1"), first)
        XCTAssertEqual(a.index(for: "au-1"), first)
    }

    /// 空いている中でいちばん小さい番号から配る。
    func testLowestFreeSlotFirst() {
        var a = ETExternalSlotAllocator(capacity: 8)
        XCTAssertEqual((0..<8).map { a.reserve("i\($0)") }, (0..<8).map { UInt8($0) })
    }

    /// 返した番号は再び使う。
    func testReleasedSlotIsReused() {
        var a = full()
        XCTAssertEqual(a.release("i3"), 3)
        XCTAssertNil(a.index(for: "i3"))
        XCTAssertEqual(a.reserve("new"), 3)
    }

    /// 9 本目は断る（ブリッジが「上限は 8」を投げる）。既に持っている id は通る。
    func testNinthIsRefused() {
        var a = full()
        XCTAssertNil(a.reserve("ninth"))
        XCTAssertNil(a.index(for: "ninth"))
        XCTAssertEqual(a.reserve("i7"), 7, "埋まっていても既存の id は同じ番号を返す")
        XCTAssertEqual(a.slots.count, 8)
    }

    /// 1 本返せば 9 本目が入る。
    func testRoomAfterRelease() {
        var a = full()
        a.release("i0")
        XCTAssertEqual(a.reserve("ninth"), 0)
        XCTAssertNil(a.reserve("tenth"))
    }

    /// 持っていない id を返しても何も起きない。
    func testReleaseUnknownIsNoop() {
        var a = full(2)
        XCTAssertNil(a.release("nobody"))
        XCTAssertEqual(a.slots.count, 2)
    }

    /// removeAll で全部空き、0 から配り直す（ETAUExternalBridge.clear）。
    func testRemoveAll() {
        var a = full()
        a.removeAll()
        XCTAssertTrue(a.slots.isEmpty)
        XCTAssertEqual(a.reserve("x"), 0)
    }

    /// 番号は重ならない。混ぜて足し引きしても 1 つの番号に 2 つの id が乗らない。
    func testSlotsNeverCollide() {
        var a = ETExternalSlotAllocator(capacity: 8)
        var rng = SystemRandomNumberGenerator()
        var live: Set<String> = []
        for step in 0..<2000 {
            let id = "id\(Int.random(in: 0..<14, using: &rng))"
            if live.contains(id), Bool.random(using: &rng) {
                a.release(id); live.remove(id)
            } else if a.reserve(id) != nil {
                live.insert(id)
            } else {
                XCTAssertEqual(a.slots.count, 8, "断るのは埋まっているときだけ (step \(step))")
            }
            let values = Array(a.slots.values)
            XCTAssertEqual(Set(values).count, values.count, "step \(step)")
            XCTAssertTrue(values.allSatisfy { $0 < 8 })
            XCTAssertEqual(Set(a.slots.keys), live)
        }
    }

    func testCapacityIsClampedToUInt8Range() {
        XCTAssertEqual(ETExternalSlotAllocator(capacity: -1).capacity, 0)
        XCTAssertEqual(ETExternalSlotAllocator(capacity: 1000).capacity, 256)
        var zero = ETExternalSlotAllocator(capacity: 0)
        XCTAssertNil(zero.reserve("x"))
    }
}
