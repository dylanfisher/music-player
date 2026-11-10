# 0192. The art viewer lists the front cover first

- **Date:** 2026-11-10
- **Status:** accepted
- **Amends:** [0172](0172-every-picture-and-bulk-covers.md): the order the viewer steps through.

## Context

The owner opened the art viewer on `Themes From Vapourspace` and found two pictures with
"2/2 Front Cover" selected. The rows show `TrackMetadata.art`, the front cover when a file has
one and else the first picture. The viewer opened on that picture but listed the file's pictures
in file order, so a file whose first picture is not its front cover opened on 2 of N.

## Decision

- The viewer lists `pictures.frontFirst`: the picture `TrackMetadata.art` is first, the rest in
  file order. It opens on 1 of N, on the art the rows show.
- The file is not changed, and the Artwork tab keeps file order, since a write puts the list back
  in that order (ADR 0172).

## Alternatives considered

- **Dropping duplicate pictures.** Rejected: the viewer lists pictures without their bytes, so
  comparing images would read every one on each open; two pictures are two pictures the file holds.
