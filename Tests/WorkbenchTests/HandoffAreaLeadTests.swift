import Foundation
import XCTest
@testable import Workbench

final class HandoffAreaLeadTests: XCTestCase {
    private struct Fixture {
        let store: Store
        let chief: Conversation
        let old: Conversation
        let new: Conversation
        let area: ConvGroup
        let secondArea: ConvGroup
        let unrelatedLead: Conversation
        let session: SessionLayout
    }

    private func makeFixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-area-lead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let store = Store(directory: dir)
        let root = ConvGroup(name: "總指揮組")
        let area = ConvGroup(name: "施工區", parentID: root.id)
        let secondArea = ConvGroup(name: "第二區", parentID: root.id)
        store.groups = [root, area, secondArea]

        let project = Project(name: "test", path: dir.path, groupID: root.id)
        store.projects = [project]

        var chief = Conversation(projectID: project.id, title: "總指揮")
        chief.groupID = root.id
        var old = Conversation(projectID: project.id, title: "舊區長")
        old.groupID = area.id
        old.model = "opus"
        old.lastOpened = Date()
        old.archiveReadmeAt = Date() // 避免 fixture 觸發摘要檔案寫入。
        var unrelatedLead = Conversation(projectID: project.id, title: "另一位區長")
        unrelatedLead.groupID = secondArea.id
        var unrelatedMember = Conversation(projectID: project.id, title: "另一區成員")
        unrelatedMember.groupID = secondArea.id

        store.conversations = [chief, old, unrelatedLead, unrelatedMember]
        let session = SessionLayout(name: "測試總指揮", windows: [], groups: [root.id], chief: chief.id)
        store.sessions = [session]

        let created = store.commanderHandoffCreate(
            caller: chief.id.uuidString,
            target: old.title,
            name: "接手中",
            model: "sonnet"
        )
        guard created.reply["ok"] as? Bool == true, let new = created.conversation else {
            throw NSError(domain: "HandoffAreaLeadTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "無法建立 handoff fixture：\(created.reply)"])
        }
        return Fixture(store: store, chief: chief, old: old, new: new,
                       area: area, secondArea: secondArea, unrelatedLead: unrelatedLead, session: session)
    }

    private func finish(_ fixture: Fixture) -> [String: Any] {
        fixture.store.commanderFinishHandoff(
            caller: fixture.chief.id.uuidString,
            oldID: fixture.old.id.uuidString,
            newID: fixture.new.id.uuidString
        )
    }

    func testFinishHandoffTransfersAreaLeadToActiveSameAreaClaudeChat() throws {
        let fixture = try makeFixture()
        fixture.store.groups[1].areaLeadID = fixture.old.id

        let result = finish(fixture)
        let new = try XCTUnwrap(fixture.store.conversation(fixture.new.id))

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertTrue(fixture.store.conversation(fixture.old.id).map { fixture.store.isArchived($0) } ?? false)
        XCTAssertEqual(new.title, fixture.old.title)
        XCTAssertEqual(new.groupID, fixture.area.id)
        XCTAssertEqual(new.modelCategory, "claude")
        XCTAssertEqual(fixture.store.group(fixture.area.id)?.areaLeadID, fixture.new.id)
        XCTAssertEqual(fixture.store.activeAreaLead(for: fixture.area, in: fixture.session)?.id, fixture.new.id)
    }

    func testFinishHandoffLeavesOtherAreaLeadUnchangedWhenOldWasNotLead() throws {
        let fixture = try makeFixture()
        fixture.store.groups[2].areaLeadID = fixture.unrelatedLead.id

        let result = finish(fixture)

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertNil(fixture.store.group(fixture.area.id)?.areaLeadID)
        XCTAssertEqual(fixture.store.group(fixture.secondArea.id)?.areaLeadID, fixture.unrelatedLead.id)
        XCTAssertEqual(fixture.store.activeAreaLead(for: fixture.secondArea, in: fixture.session)?.id,
                       fixture.unrelatedLead.id)
    }

    func testFinishHandoffTransfersEveryAreaLeadReferenceToNewChat() throws {
        let fixture = try makeFixture()
        fixture.store.groups[1].areaLeadID = fixture.old.id
        fixture.store.groups[2].areaLeadID = fixture.old.id

        let result = finish(fixture)

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(fixture.store.groups.filter { $0.areaLeadID == fixture.new.id }.count, 2)
        XCTAssertFalse(fixture.store.groups.contains { $0.areaLeadID == fixture.old.id })
        XCTAssertEqual(fixture.store.activeAreaLead(for: fixture.area, in: fixture.session)?.id, fixture.new.id)
        // Conversation 只隸屬一個直接區；activeAreaLead 仍套用原本的直接隸屬驗證。
        XCTAssertNil(fixture.store.activeAreaLead(for: fixture.secondArea, in: fixture.session))
    }
}
