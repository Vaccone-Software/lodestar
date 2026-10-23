# Design contracts

DESIGN.md says where Lodestar's look is going and why. These contracts say exactly what it is, one foundation or primitive at a time, in numbers a test can hold and a render can show.

Each contract has the same parts:

- **What it is for**, and when to reach for it instead of something else.
- **Origin**: where the decision came from, including what was tried and refused.
- **Values**: every number, named once.
- **Rules**: what always holds, and what never happens.
- **Enforcement**: the tests that hold the values and the rules.
- **Renders**: the gallery pictures that show it, made from the code by `scripts/render-gallery.sh`. Pictures are never committed; they are regenerated, so they cannot go stale.
- **Status**: whether the code does what the contract says yet.

A contract changes before the code does. A change to a value lands with the code and tests that make it true, and the render is checked by eye before it ships.

## Foundations first

Primitives are made of foundations, so the foundations are settled first.

| #   | Contract    | Status  |
| --- | ----------- | ------- |
| 01  | Colour      | Built   |
| 02  | Type        | Built   |
| 03  | Geometry    | Built   |
| 04  | Material    | Built   |
| 05  | Motion      | Built   |
| 06  | Eye comfort | Built   |

Then the primitives, each made only of the foundations above: the key, the slab, the well, the row, stops, and the countdown key. Then sound.

## The prototype

A full prototype of Ceramic was built on the branch `design/ceramic` in October 2026 and is kept there as a reference, not merged. It proved the direction and showed where rules were missing: wherever the design said what a thing was without saying exactly how, each surface decided for itself, and the results disagreed. Each contract records what the prototype taught about its subject under **Prototype lessons**.
