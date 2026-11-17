import Foundation
import Testing

@testable import OpenDDCamKit

@Suite struct ModelTests {
    @Test func baseInfoFromObject() {
        let info = BaseInfo(Fixture.response("base_info").payload)
        #expect(info.nickname == "VOLVO D317")
        #expect(info.model == "VOLVO D317")
        #expect(info.version == "v3.5.2.0")
        #expect(info.sdCapacity == 62_000_000)
        #expect(info.sdSpare == 31_000_000)
        #expect(info.totalRuntime == 1234)
        #expect(info.needsUpdate == false)
        #expect(info.isHEVC == false)
        #expect(info.bitrates["hbbitrate"] == 8000)
        #expect(info.cardState == .ok)
        #expect(info.hasMainUser == false)
    }

    @Test func baseInfoFromStringDataAndStringNumbers() {
        let info = BaseInfo(Fixture.response("base_info_string_data").payload)
        #expect(info.sdCapacity == 62_000_000)
        #expect(info.isHEVC)
        #expect(info.needsUpdate)
        #expect(info.hasMainUser)
        #expect(info.isMainUser(uid: "randomImeiAAAA"))
        #expect(info.isMainUser(uid: "randomImeiBBBB") == false)
    }

    @Test func baseInfoMissingFieldsAreNil() {
        let info = BaseInfo([:])
        #expect(info.model == nil)
        #expect(info.sdCapacity == nil)
        #expect(info.cardState == .unknown)
        #expect(info.isHEVC == false)
        #expect(info.needsUpdate == false)
        #expect(info.bitrates.isEmpty)
    }

    @Test func cardStates() {
        #expect(BaseInfo(["sdcapacity": .number(0)]).cardState == .missing)
        #expect(BaseInfo(["sdcapacity": .number(-1)]).cardState == .needsFormat)
        #expect(BaseInfo(["sdcapacity": .string("-1")]).cardState == .needsFormat)
        #expect(BaseInfo(["sdcapacity": .number(5)]).cardState == .ok)
    }

    @Test func emptyAndNullDefaultUserMeanNoMainUser() {
        for v in ["", "null", " "] {
            #expect(BaseInfo(["default_user": .string(v)]).hasMainUser == false)
        }
        #expect(BaseInfo(["default_user": .null]).hasMainUser == false)
    }

    @Test func storageInfo() {
        let s = StorageInfo(Fixture.response("storage_info").payload)
        #expect(s.sdCapacity == 62_000_000)
        #expect(s.sdSpare == 31_000_000)
        #expect(s.extSdCapacity == 0)
        #expect(s.normalRecordings == 120)
        #expect(s.eventRecordings == 4)
        #expect(s.cycleRecordSpace == 30_000_000)
        #expect(s.isSmartCard == false)
    }

    @Test func storageInfoEmpty() {
        let s = StorageInfo([:])
        #expect(s.sdCapacity == nil)
        #expect(s.isSmartCard == false)
    }

    @Test func playbackListSkipsBadEntriesAndParsesStrings() {
        let list = PlaybackList(Fixture.response("playback_list").payload)
        #expect(list.count == 2)
        // entry without a name and the string entry are dropped
        #expect(list.files.count == 2)
        let first = list.files[0]
        #expect(first.startTime == 1_795_000_000)
        #expect(first.endTime == 1_795_000_060)
        #expect(first.size == 120_000_000)
        #expect(first.matchValue == 1)
        #expect(first.hasSmallStream == false)
        #expect(list.files[1].hasSmallStream)  // matchval "ALL"
    }

    @Test func playbackListMissingFile() {
        let list = PlaybackList([:])
        #expect(list.files.isEmpty)
        #expect(list.count == nil)
    }

    @Test func playbackListFileMissingTimesIsKept() {
        let l = PlaybackList(["file": .array([.object(["name": .string("a.MP4")])])])
        #expect(l.files.first?.startTime == nil)
    }

    @Test func eventList() {
        let events = EventEntry.list(Fixture.response("event_list").payload)
        #expect(events.count == 2)
        #expect(events[0].imageName == "G_20261117101230.JPG")
        #expect(events[0].imageSize == 120_000)
        #expect(events[0].bigVideo?.name == "G_20261117101230_B.MP4")
        #expect(events[0].bigVideo?.start == 1_795_000_300)
        #expect(events[0].bigVideo?.end == 1_795_000_360)
        #expect(events[0].bigVideo?.size == 30_000_000)
        #expect(events[0].smallVideo == nil)
        #expect(events[1].smallVideo?.name == "G_20261117101230_B_S.MP4")
        #expect(events[1].smallVideo?.start == 1_795_000_300)
        #expect(events[1].smallVideo?.size == 500_000)
        #expect(events[1].imageName == nil)
    }

    @Test func lockedFilesDropEmptyNames() {
        #expect(LockedFiles.names(Fixture.response("locked_list").payload) == ["20261117101000_B.MP4"])
    }

    @Test func generalQueryResult() {
        let r = GeneralQueryResult(Fixture.response("general_query").payload)
        #expect(r.int("event_before_time") == 10)
        #expect(r.int("gsensor_mode") == 3)  // string number tolerated
        #expect(r.string("mic_switch") == "on")
        #expect(r.string("bad") == nil)  // entry without value
        #expect(r.int("mic_switch") == nil)
    }

    @Test func mailboxMessagesAcceptObjectOrStringData() {
        let msgs = MailboxMessage.list(Fixture.response("mailbox").payload)
        #expect(msgs.count == 3)
    }
}
