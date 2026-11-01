# 0025. Threat model: hostile files, the tag writer, SQL, paths, the bundle and the LAN

- **Date:** 2026-10-31
- **Status:** accepted
- **Amends:** [0020](0020-tag-writing.md), [0023](0023-failure-table.md)

## Context

Phase 14c asks for a written threat model with a test or a check for every threat in it. The
app reads 43k files from a NAS that other people's downloads, rippers and taggers wrote, and
phase 11 made it write some of them. Phase 9 will put an HTTP server and a receiver connection
on the LAN. The survey read each entry point in the code as it is: every parser and the byte
reader under them, the tag writer's file handling, every SQL string, the files read at launch,
and `scripts/bundle`. It found no secret anywhere in the tree.

## Decision

**Who attacks.** Four kinds, and the model is written against them:

- **A hostile file:** anything in a watched folder, written by a tool or a person the owner
  doesn't control. Its bytes, its name and its tags are input. This is the main one.
- **Another NAS user:** someone who can write into a shared folder of the library, but not into
  the owner's Mac. They can already change any music file there, so what matters is that the
  app doesn't carry their writes anywhere else, through a link it follows.
- **A LAN device:** anything that can send packets to the Mac's network interfaces (phase 9).
- **Another process of the owner's user:** it can already write the config, the state file, the
  journal and the database, and run code as the owner. The app checks those files for damage and
  stays correct, but doesn't defend against this user. Rows for it say so.

**The table.** Each row's test is in `./scripts/check` unless it names a script.

| # | Asset | Attacker | Entry point | Mitigation | Test or check |
|---|---|---|---|---|---|
| 1 | the scan; the app's memory | hostile file | a declared size or offset in any parser (atom, box, chunk, block, frame, comment count, descriptor) | every read goes through `ByteReader.bytes`, which refuses a range past the end of the file or over 16 MiB before reading; every field read is bounds-checked by `Bytes`; counts are checked against the bytes left | `oversizedLengthsAreMalformedNotAllocated`, `hostileSizesInEveryParserAreTypedErrors` |
| 2 | the scan | hostile file | sizes that overflow when added (64-bit MP4 sizes, `size + 8`, duration × rate) | sizes are checked against what's left, never summed first; a 64-bit size over `Int.max` and a duration that would overflow are refused | `hostileSizesInEveryParserAreTypedErrors` |
| 3 | the app's memory | hostile file | an art length, recorded by the scan and read by the window, the tag editor and the writer | `readArt` refuses art past 64 MiB (`maximumArtBytes`) before allocating it; real art is under 2 MB | `artLongerThanTheMaximumIsRefusedBeforeReading` |
| 4 | the app's memory | hostile file | an image that decodes to billions of pixels, or a few hundred bytes that declare one | every decode of art, the window's and the tag editor's, goes through `thumbnail(of:maxPixelSize:)`, which ImageIO decodes straight to the thumbnail; a 400-megapixel PNG of 1.7 MB peaked at 23 MB | `aHugeImageDecodesOnlyToItsThumbnail`, `aTinyImageDeclaringAHugeOneDecodesOnlyToAThumbnailOrNot` |
| 5 | the scan; the writer | hostile file | nesting: atoms in atoms, chunks in chunks | the reader's walks are loops over a fixed path (`moov`, `trak`, `mdia`, `minf`, `stbl`; `udta`, `meta`, `ilst`), so nesting can't recurse; the writer's `MP4Box` opened every container it knows at any depth and overflowed the stack, and now refuses nesting past 8 | `aDeeplyNestedMP4IsRefusedByTheWriter` |
| 6 | the scan | hostile file | offsets past the end: art, chunk offsets, a file that shrinks | `Bytes` throws a typed failure instead of trapping; `readArt` rechecks against the file's size now; `FileSource` reads with `pread`, never a map, so a shrinking file fails a read instead of raising SIGBUS | `blocksTooShortForTheirFieldsAreMalformed`, `artPastTheEndOfAChangedFileIsMalformed`, `everyTruncationFailsOrParses`, `fuzzedFilesFailOrParse` |
| 7 | the index; the UI | hostile file | text frames: invalid UTF-8 and UTF-16, unpaired surrogates, a lone byte-order mark, odd lengths, NUL, bidi and other controls | each decode is total: invalid text is read with a `badText` warning, never a trap; text is read up to a NUL (row 16); bidi and other controls are kept as text, and escaped where the command line prints them (row 9) | `hostileTextInEveryEncodingReadsWithWarnings` |
| 8 | the whole scan | hostile file | any parser failure | a failure is a `MetadataError` recorded for that file in Problems; the scan carries on | `hostileFilesFailAloneAndTheScanCarriesOn` |
| 9 | the owner's terminal | hostile file | a file name or tag text the command line prints (`--scan`, `--play`, errors, the scan's issues file) | each printed line is escaped on its own: every control character (C0 with newline, return and tab, DEL, C1) prints as `\u{..}`, so a name can't send escape sequences or print a line that looks like the app's | `controlCharactersAreEscapedForTheTerminal` |
| 10 | files outside the library | hostile file; NAS user | a symbolic link in a watched folder | the walk reports a link and doesn't follow it | `skipsHiddenFilesAndReportsSymbolicLinks` |
| 11 | a music file | NAS user | the tag writer given a path that is a symbolic link, or one swapped in after the read | `FileIdentity` reads with `lstat` and refuses anything but a regular file, before reading and again before the rename; the original is opened with `O_NOFOLLOW` and its `fstat` must match that `lstat`, so neither a link nor another file swapped in between is made into the temp file. A swap between the last `lstat` and `rename` stays open (row 14) | `aSymbolicLinkIsRefusedAndItsTargetUnchanged`, `anOriginalSwappedBeforeTheTempFileIsRefused` |
| 12 | a music file | NAS user | a hard link to the file | refused: the rename would leave the other name on the old bytes | `aFileWithAnotherHardLinkIsRefused` |
| 13 | any file the owner can write | NAS user | the temp file beside the original: a name created first, a link, a file or a hard link swapped in | temp names are `.<name>.<128 random bits>.tagwrite`, so nobody can create one first; names an earlier write left are unlinked (a link, not its target). The temp file is cloned from the open original with `fclonefileat`, or created with `O_CREAT \| O_EXCL`, both refusing an existing name; it's opened through the folder's descriptor with `O_NOFOLLOW` and must be a regular file of this user with one link, on the original's volume, and the file its name names. Just before the rename its name must still hold that file, with one link. Still open: the rename goes by path, so a swap between that check and `rename`, or the folder itself swapped for a link, isn't caught; whoever can do either can already write the folder | `aLinkPlantedAtATempNameIsRemovedAndItsTargetUnchanged`, `theClonedTempFileIsntOpenedThroughALink`, `aTempFileSwappedBeforeTheRenameIsRefused` |
| 14 | a music file | another writer (Swinsian, a NAS user) | a change between the read and the rename (TOCTOU) | device, inode, size and mtime are compared just before the rename; a change leaves the file as the other writer made it. The gap between that check and `rename` stays: macOS has no compare-and-rename, and whoever can use it can already write the file | `aFileChangedDuringTheWriteIsLeftAsTheOtherWriterMadeIt` |
| 15 | the index | hostile file; the owner typing | smart rule text and search text | every value is bound (`?`), never spliced; LIKE's `%`, `_` and `\` are escaped; FTS5 phrases double their quotes and nothing else of the query is typed | `everyRuleFieldAndTheSearchBoxMatchHostileTextLiterally` |
| 16 | correct results | hostile file; the owner typing | NUL in a tag, a rule or a search | SQLite text was bound with length `-1` and read with `String(cString:)`, so it ended at the NUL; it's bound and read by byte count now. SQLite's LIKE still stops at a NUL, so tags in every format are read up to one, as ID3 always was, with a `badText` warning when text follows it; a rule holding a NUL is refused; a NUL in the search box separates words, where it used to end the FTS5 query inside a phrase and fail it | `textWithNULRoundTripsWhole`, `hostileTextInEveryEncodingReadsWithWarnings`, `ruleTextPastTheLimitIsRefused`, `everyRuleFieldAndTheSearchBoxMatchHostileTextLiterally` |
| 17 | listing a playlist | the owner typing | rule text longer than SQLite's 50,000-byte LIKE pattern | `SmartRule.problem` refuses text over 10,000 UTF-8 bytes, when it's saved rather than every time it's listed | `ruleTextPastTheLimitIsRefused` |
| 18 | the database | another process of the owner | table names read back from `sqlite_master` when the schema is rebuilt | they went into `DROP TABLE "..."` without doubling quotes, and `execute` runs every statement it's given; `quotedIdentifier` doubles them | `aQuotedIdentifierStaysOneName`, `aTableNamedToBreakOutOfItsQuotesIsDroppedAlone` |
| 19 | the database | — | every other SQL string built at runtime | audited (below): each splices only constants, enum cases and `?` lists | the audit grep below |
| 20 | the scan | the owner's config | watched folder paths and include and exclude patterns | read only; the scanner never writes into a watched folder; patterns are `fnmatch` over one component at a time | `missingFolderRemovesNothing`, `skipsHiddenFilesAndReportsSymbolicLinks` |
| 21 | the config file | another process of the owner | `config.json`, read at launch and on change | strict: unknown keys and bad values at every level are reported with their line, defaults apply, the file is never written over; nesting past Foundation's 512 levels is a parse error | `aBrokenFileAppliesNothingAndIsNeverWrittenOver`, `deeplyNestedConfigAndStateAreReported` |
| 22 | the state file | another process of the owner | `state.json`, read at launch; it holds a folder path for the sidebar | decoded strictly, discarded whole and reported if it doesn't match; the folder path only filters the index | `aStateFileThatDoesntMatchIsDiscardedAndReported`, `deeplyNestedConfigAndStateAreReported` |
| 23 | the DAC's settings | another process of the owner | the device record, read at launch to restore a device after a crash | strict decoding; only a device the HAL lists by that UID is touched, with formats the HAL validates; a record that doesn't decode is deleted and reported | `aRecordThatDoesntReadIsDiscardedAndReported` |
| 24 | a music file | another process of the owner | the undo journal's records, which name the path undo writes | strict decoding; undo writes only a regular file whose device, inode, size and mtime match the record, through the same temp-file write, and the result must hash as the record says. A forged record that matches all of that is a forgery by a process that could write the file itself | `aRecordWithAnUnknownKeyAnywhereIsDiscardedAndReported`, `aFileEditedSinceIsNotUndone` |
| 25 | the library | another process of the owner | `library.sqlite` and its lock file, opened at launch | a file SQLite can't read is moved aside and reported; rows that don't decode are errors, never defaults | `aLibraryFileThatIsntADatabaseIsMovedAsideAndReported` |
| 26 | the app's code | anything that injects into a process | the bundle's signature | a release bundle is ad-hoc signed with the hardened runtime and no entitlements, so no library injection through `DYLD_` variables, no unsigned executable memory, and no debugger attaching without root. A debug bundle adds `get-task-allow` so lldb can attach; the release check fails on it | `scripts/check-signature`, run by `scripts/bundle release`; `scripts/check-signature-test` |
| 27 | the app working | — | the hardened runtime itself | the hardened app launches, opens its window and draws it with `--home` in a temp folder; it loads only system frameworks, so library validation has nothing to refuse. It would refuse a third-party AudioToolbox codec plugin, which is accepted: the app decodes with the system's codecs only | `scripts/check-signature --launch` |
| 28 | the owner's files | LAN device | phase 9's HTTP server | requirements for phase 9, below | phase 9's tests |
| 29 | the app | LAN device | SSDP replies and device descriptions | requirements for phase 9, below | phase 9's tests |
| 30 | the receiver; the app | LAN device | the Denon control connection on TCP 23 | requirements for phase 9, below | phase 9's tests |
| 31 | the scan's memory and time | hostile file | millions of tiny structures (empty comments, zero-size frames), each a loop turn and often a warning | a file's walks stop at 100,000 steps (`ByteReader.maximumSteps`) as malformed; a file keeps 100 warnings, then one counting the rest | `aFileOfTinyStructuresStopsAtTheBudget`, `warningsPastTheCapAreCountedInOne` |
| 32 | the status bar; the scan report | hostile file; NAS user | a folder of a million links or unreadable entries | a scan lists 100 walk problems (`ScanPipeline.maximumIssues`), then one counting the rest; every unreadable path, listed or not, still keeps the scan from removing anything under it | `aWalkListsAtMostItsCapOfProblemsAndStillProtectsEveryUnreadableFolder` |
| 33 | the scan | hostile file; NAS user | a FIFO or a device among the music, or a link swapped in for a file after the walk | `FileSource` opens with `O_NONBLOCK` and `O_NOFOLLOW`, requires a regular file, then clears `O_NONBLOCK`; links are never read, as the walk never follows them | `aFIFOOrALinkIsRefusedWithoutBlocking` |
| 34 | every file on the disk | the owner's config | a watched folder of `/`, the home folder or a system root | refused by the config check with its line, after standardizing the path | `aSystemFolderOrTheHomeFolderIsRefusedAsAWatchedFolder` |
| 35 | the log | hostile file | a path or tag text with a line break, logged | accepted, not escaped: `os.Logger` keeps interpolated strings private by default, so the stored log shows `<private>`; where private data is shown (a debugger attached, a logging profile), each entry is its own record with its own timestamp and category, so a line break can't make one look like another | `rg 'privacy: .public' Sources` lists only device IDs and formats |
| 36 | the app's memory; files outside the library | hostile file | a playlist file given to Import Playlist… or dropped on the sidebar | opened by `FileSource` (`O_NOFOLLOW`, `O_NONBLOCK`, a regular file only) and refused over 16 MiB before it's read; UTF-16 refused with a reason ([0032](0032-playlist-files.md)) | `aLinkAFolderOrAnUnknownExtensionIsNotRead`, `filesPastTheCapsAreRefusedOrCut` |
| 37 | the import's memory and time; the Problems window | hostile file | a long line, millions of entries or of bad lines | 4 KiB a line, 100,000 entries, 100 problems kept and the rest counted; the report lists 100 missing paths, then a count | `filesPastTheCapsAreRefusedOrCut`, `importAndExportReportsAreCappedWithACount`; `scripts/fuzz playlist-file` |
| 38 | files outside the library; the network | hostile file | an entry naming a URL, a Windows path, `..` past the root, a link | only `file:` URLs with no host or `localhost`; other schemes and Windows paths are reported; `..` is folded on the text and the path goes only to an index lookup, never to `open`, `stat` or `realpath` | `hostileEntriesAreSkippedAndReportedWithTheirLine`, `pathsMatchInEitherUnicodeForm` |
| 39 | the index; the UI | hostile file | invalid UTF-8, NUL, a BOM, CR line ends, Windows-1252 | each line decoded on its own: M3U8 is UTF-8 and a bad line is reported; M3U and PLS fall back to a total Windows-1252; a NUL anywhere skips the line | `legacyM3UIsUTF8WhenValidElseWindows1252`, `aBOMCRLFAndLoneCRAreLineEndsNotText` |
| 40 | a music file; a watched folder | — | Export Playlist… | written only to the URL the save panel returns, atomically; a path with a line break or NUL, which would make a second entry, is reported and not written | `m3u8IsWrittenWithLengthsNamesAndNFCPaths`, `anImportedPlaylistOpensAndExportsInTheTableSort` |

**What the SQL audit found.** `rg -n '\\\(' Sources/Core/Library Sources/Primitives/SQLite
Sources/App/MusicPlayer/ScanCommand.swift`, read for every string that reaches `prepare`,
`statement` or `execute`. Every interpolation splices one of: a `TrackColumn` or `SmartField`
expression, a `SmartOrder` clause, `trackJoins`, `whereClause` built from those, a schema
table-name constant, an `ASC`/`DESC`, or a `?, ?, …` list sized by `inListSize`. Every value
from a user or a file is bound. The one exception was row 18. Bench and FailureDrill splice only
their own constants.

**Requirements for phase 9.** Phase 9 copies these into its section, and each gets a test there
against a loopback stand-in:

- **Local subnet.** For each interface that's up, its IPv4 address and netmask, or its IPv6
  prefix; an IPv6 link-local address (`fe80::/10`) counts only with the zone of the interface
  it arrived on. On a Mac with several interfaces, an address is local to the interface whose
  subnet holds it, and replies and connections are matched against that interface alone. The
  interface list is injected, so the filtering is tested with made-up interfaces.
- **Bind.** The HTTP server listens on the one interface address the chosen renderer reached
  the Mac on, never on every interface, and on a port the system picks. It accepts
  connections only from that interface's subnet, and stops when no renderer is in use.
- **What's served.** Only tracks the index holds, by a token mapped to a track ID, never a path
  in the URL. Tokens are 128 random bits, made per track per session and expired when the
  session ends or after 24 hours. A request for anything else is 404 without touching the file
  system. No directory listings, no symbolic links followed, music files opened read-only.
- **Requests.** `GET` and `HEAD` only. The `Host` header must be the address and port the
  server bound, which stops DNS rebinding. A request line and headers over 8 KiB, a body, more
  than one `Range`, or a range outside the file is refused; at most 8 connections at once, each
  closed after 30 s idle.
- **SSDP.** Replies are hostile input: read only from the local subnet, at most 64 KiB, and a
  `LOCATION` is followed only to an `http` address on the subnet the reply came from, with
  redirects refused. Device descriptions and SOAP replies are capped at 1 MiB, parsed with
  `XMLParser` with external entities off, and time out after 5 s. A renderer's name is display
  text, escaped as row 9.
- **Receiver control.** The address comes only from SSDP on the local subnet. Status lines are
  hostile input: at most 128 bytes each, and at most 128 bytes buffered without a carriage
  return, past which the connection is dropped and reported; unknown lines ignored; values
  range-checked before the model takes them. Commands are built from the registry, never from
  received text. The protocol has no authentication, so the app sends only what the owner
  asked for.
- **Info.plist.** `NSLocalNetworkUsageDescription` and the Bonjour types it uses (phase 9's
  Info.plist item); no new entitlements unless `scripts/check-signature`'s list grows with a
  reason.

**Distribution, for the owner.** The ad-hoc signature runs on the Mac that built it and on the
owner's other Macs after copying. Shipping to anyone else needs a Developer ID Application
certificate in the owner's keychain, and a notarytool profile stored once with
`xcrun notarytool store-credentials <profile> --apple-id <apple id> --team-id <team id>`.
Then, on a release bundle, with the owner's values in angle brackets:

```
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <name> (<team id>)" <path>/MusicPlayer.app
ditto -c -k --keepParent <path>/MusicPlayer.app MusicPlayer.zip
xcrun notarytool submit MusicPlayer.zip --keychain-profile <profile> --wait
xcrun stapler staple <path>/MusicPlayer.app
```

Phase 13 (release readiness) owns doing this and changing `scripts/bundle` to match. None of
it is in the repo, and no agent touches keychains or certificates.

## Alternatives considered

- **App Sandbox.** Rejected for now: the app reads folders anywhere, including SMB mounts the
  owner names in a text config file, which the sandbox allows only through security-scoped
  bookmarks made by an open panel. Revisit at the first public release.
- **Following symbolic links in the library, with a loop check.** Rejected: a link on a NAS
  share is resolved on the Mac, so it could point the scan, and the writer, at the owner's own
  files.
- **A cap on whole-file reads of the config, state and journal files.** Rejected: only the
  owner's own processes write them, and they can do worse than a large file.
- **`PRAGMA trusted_schema = OFF` and `SQLITE_DBCONFIG_DEFENSIVE`.** Rejected for now: the
  database is the owner's own file (row 25), and the FTS5 table would need checking against
  them. Revisit if a library can ever come from someone else.
- **Refusing art at scan time.** Rejected: the scan records where art is without reading it,
  and a huge one costs nothing until it's read, where row 3 refuses it.

## Consequences

A file whose art is over 64 MiB shows no art, and the tag writer refuses it, since it can't
read the art back to check the write. An MP4 whose containers nest deeper than 8 can't be
edited. A smart rule's text stops at 10,000 bytes and can't hold a NUL. A file whose walk
takes over 100,000 steps fails as malformed, and a file or a scan with over 100 problems lists
100 and a count. FIFOs, devices and links among the music are reported, never read. `/`, the
home folder and the system roots can't be watched. Tag text after a NUL
is dropped with a warning in every format, as ID3 always did; a file already indexed changes
only when it's next read. Every phase that adds an entry point adds its row here.
