import Darwin
import Foundation
import Testing
@testable import LocalhostKit

private func row(
    port: UInt16,
    project: String? = nil,
    compose: String? = nil,
    ours: Bool = true
) -> ListenerPresentation {
    let attribution: ListenerPresentation.Attribution
    if let project {
        attribution = .project(
            name: project, root: URL(fileURLWithPath: "/tmp/\(project)"), source: .packageJSON)
    } else if let compose {
        attribution = .container(Container(
            name: "\(compose)-db-1", image: "postgres:16",
            composeProject: compose, composeService: "db", publishedPorts: [port]))
    } else {
        attribution = .nothing
    }
    return ListenerPresentation(
        listener: Listener(
            port: port,
            addresses: ["127.0.0.1"],
            families: [.ipv4],
            process: ProcessIdentity(
                pid: pid_t(port), startedAt: ours ? 1 : nil,
                uid: ours ? getuid() : 0, name: "node", workingDirectory: "/tmp")),
        attribution: attribution)
}

@Suite("Project grouping")
struct GroupingTests {
    @Test("a repository and its compose stack become one group")
    func repositoryAndComposeGroupTogether() throws {
        // The payoff: nobody configured this. The frontend resolved to a project
        // root and the database reported its own compose project.
        let sections = ListenerGrouping.sections(from: [
            row(port: 3000, project: "campo"),
            row(port: 4000, project: "campo"),
            row(port: 5432, compose: "campo"),
        ])
        #expect(sections.count == 1)
        #expect(sections.first?.project == "campo")
        #expect(sections.first?.rows.count == 3)
    }

    @Test("a group of one is not a group")
    func singleRowIsNotGrouped() {
        let sections = ListenerGrouping.sections(from: [row(port: 3000, project: "solo")])
        #expect(sections.count == 1)
        #expect(sections.first?.project == nil, "a heading over one row says nothing")
    }

    @Test("unattributed rows never group with each other")
    func unattributedRowsStaySeparate() {
        let sections = ListenerGrouping.sections(from: [row(port: 7000), row(port: 7001)])
        #expect(sections.count == 2)
        #expect(sections.allSatisfy { $0.project == nil })
    }

    @Test("relevance order survives grouping")
    func orderIsPreserved() throws {
        let sections = ListenerGrouping.sections(from: [
            row(port: 3000, project: "campo"),
            row(port: 9999),
            row(port: 4000, project: "campo"),
        ])
        // campo appears where its first row was, and the loose row keeps its place.
        #expect(sections.map(\.project) == ["campo", nil])
        #expect(sections[0].rows.map(\.listener.port) == [3000, 4000])
    }

    @Test("a group offers only the rows it may signal")
    func onlyOurProcessesAreTerminable() throws {
        let sections = ListenerGrouping.sections(from: [
            row(port: 3000, project: "campo"),
            row(port: 4000, project: "campo", ours: false),
        ])
        let section = try #require(sections.first)
        #expect(section.rows.count == 2)
        #expect(section.terminableRows.count == 1)
    }
}

@Suite("Port answers")
struct PortAnswerTests {
    @Test("a port nothing holds is free")
    func freePort() {
        #expect(ListenerSearch.answer(for: "3000", rows: [row(port: 3001, project: "rilo")])
                == .free(3000))
    }

    @Test("a port something holds names the holder")
    func takenPort() throws {
        let holder = row(port: 3000, project: "campo")
        guard case let .taken(found) = ListenerSearch.answer(for: "3000", rows: [holder]) else {
            Issue.record("expected the port to be taken")
            return
        }
        #expect(found.label == "campo")
        #expect(found.canTerminate)
    }

    @Test("prefers a holder we can actually free")
    func prefersTerminableHolder() throws {
        // Both bind 3000; only one of them can be moved aside.
        let rows = [row(port: 3000, ours: false), row(port: 3000, project: "campo")]
        guard case let .taken(found) = ListenerSearch.answer(for: "3000", rows: rows) else {
            Issue.record("expected the port to be taken")
            return
        }
        #expect(found.canTerminate)
    }

    @Test("a name is not a port question")
    func nameIsNotAPort() {
        #expect(ListenerSearch.answer(for: "campo", rows: []) == .notAPort)
    }
}
