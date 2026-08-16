# ``AemiKernel``

The zero-dependency byte, number, ASCII, UTF-8, and hashing kernel shared by every g-cqd engine.

## Overview

`AemiKernel` is the foundation tier: pointer-level byte buffers and readers, variable-length and
little/big-endian integer codecs, overflow-checked arithmetic, ASCII classification, RFC 3629 UTF-8
validation, percent-coding, and non-cryptographic hashing. It is **Foundation-free**,
**swift-syntax-free**, and carries **no transitive package dependency** beyond the Swift standard
library and `Synchronization` — so the portable `ADJSONCore` engine and the apple-docs
zero-external-dependency dylib can link it without changing their resolution graphs.

The tier adopts SE-0458 strict memory safety: every unsafe construct is explicitly `unsafe`, so any
new unsafe use is flagged at compile time. The guiding principle is **no traps at trust boundaries**
— size and offset arithmetic on untrusted input returns `nil` (see ``Swift/FixedWidthInteger/checkedAdding(_:)``)
rather than aborting the process.

## Topics

### Checked arithmetic

- ``Swift/FixedWidthInteger/checkedAdding(_:)``
- ``Swift/FixedWidthInteger/checkedSubtracting(_:)``
- ``Swift/FixedWidthInteger/checkedMultiplied(by:)``

### Byte buffers & readers

- ``ByteReader``
- ``ByteCompare``
- ``ByteBufferPool``

### Integer & byte codecs

- ``Varint``
- ``Swift/UnsafeRawBufferPointer/loadLE16(_:)``
- ``Swift/UnsafeRawBufferPointer/loadLE32(_:)``
- ``Swift/UnsafeRawBufferPointer/loadLE64(_:)``
- ``Swift/UnsafeRawBufferPointer/loadBE16(_:)``
- ``Swift/UnsafeRawBufferPointer/loadBE32(_:)``
- ``Swift/UnsafeRawBufferPointer/loadBE64(_:)``
- ``Swift/UnsafeMutableRawBufferPointer/storeLE16(_:at:)``
- ``Swift/UnsafeMutableRawBufferPointer/storeLE32(_:at:)``
- ``Swift/UnsafeMutableRawBufferPointer/storeLE64(_:at:)``
- ``Swift/UnsafeMutableRawBufferPointer/storeBE16(_:at:)``
- ``Swift/UnsafeMutableRawBufferPointer/storeBE32(_:at:)``
- ``Swift/UnsafeMutableRawBufferPointer/storeBE64(_:at:)``

### ASCII, hex & UTF-8

- ``ASCII``
- ``Hex``
- ``UTF8Validation``

### Percent-coding

- ``PercentCoding``

### Hashing

- ``XXH64``
