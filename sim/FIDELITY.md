# Simulator fidelity notes

Sources: the extracted jars under the session scratchpad (`jars/`), read with `javap -c -p`, plus the real CC 1.63 ROM in `sim/rom`.

## ComputerCraft 1.63 (tomo1 build)
- Every computer runs the real `bios.lua` with the real ROM mounted read only at `/rom`.
- Event queue capacity is 256 per computer (`ComputerThread` uses `LinkedBlockingQueue(256)`). Extra events are dropped silently.
- `os.queueEvent` called before a program first yields after boot is dropped. Seen in game: a packed program that queued its own wake-up event at boot waited forever, yet ran fine when started from the shell. A timer started at that point still fires, so the first yield should wait on `os.startTimer(0)`.
- `os.reboot()` and a start request take effect only once more than 50 ticks have passed since the previous start (`Computer.advance` checks `m_ticksSinceStart > 50`). The harness `computer:reboot()` and `computer:boot()` skip this delay.
- Timers count down `0.05` per tick in doubles (`OSAPI.advance`), so `os.startTimer(0.5)` fires on the 11th tick and `sleep(5)` takes 101 ticks. The sim does the same.
- World time is shared by all dimensions (1.6.4 dimensions use the overworld's world info), so `os.time()` and `os.day()` are the same everywhere.
- `FileMount.MINIMUM_FILE_SIZE` is 512. Files and directories each count at least 512 bytes toward capacity. Computer capacity is 1000000 and floppy capacity is 125000.
- Used space is measured when the mount is created (at boot for the hard drive, at each insertion for a floppy). A root directory created during the session is not counted until the next measurement, as in `FileMount.create`.
- Text handles go through `BufferedWriter` and `OutputStreamWriter`, so bytes reach the counting stream in 8192 byte chunks once 16384 are buffered. A chunk that does not fit raises `Out of space` from `write`. What is still buffered at `flush` or `close` is counted then, and if it does not fit it is dropped without an error. Binary handles are unbuffered, so the first byte that does not fit raises `Out of space`. `fs.copy` and `fs.move` raise `Out of space` too. Writing to a closed handle raises `Stream closed`.
- Wireless modem range is 64, or 16 in a storm (rain and thunder). Above y=96 it rises linearly to 384 (96 in a storm) at build height. A receiver accepts when the distance is <= max(sender range, receiver range). Delivery stays within one dimension and is synchronous: `WirelessNetwork.transmit` queues `modem_message` on each receiver during the `transmit` call. Wired messages go through `TileCable.m_transmitQueue` and arrive on the next tick.
- `modem_message` arguments are (side, channel, replyChannel, message, distance). Channels are 0 to 65535, with at most 128 open per modem.
- Wired modem methods are open, isOpen, close, closeAll, transmit, isWireless, getNamesRemote, isPresentRemote, getTypeRemote, getMethodsRemote and callRemote. There is no getNameLocal. Remote names are `<type>_<n>`.
- Monitor size is `floor((blocks - 0.3125) / (scale * 6 / 64) + 0.5)` wide and `floor((blocks - 0.3125) / (scale * 9 / 64) + 0.5)` high. Checked values: 1x1 at scale 1 is 7x5, 3x3 at 0.5 is 57x38, 8x6 at 0.5 is 164x81. A scale change that alters the size fires `monitor_resize(name)`. `monitor_touch(name, x, y)` fires only on advanced monitors.
- Native term has no blit and no getTextColor. There is only the `bit` API, no `bit32`.

## MoarPeripherals 1.6.4-1.63-1.5 (BitNet)
- The tower controller has type `bitnet_tower` with methods `transmit(payload)` and `isTowerComplete()`. `transmit` takes exactly one non nil argument and returns `true`, or `false, "BitNet Communications Tower incomplete."`.
- The mini antenna has type `bitnet_antenna`. Its `transmit(payload)` returns nothing.
- The event is `bitnet_message(attachmentName, payload, distanceTravelled)`.
- `BitNetRegistry$DelayedMessage` sets the delay to `(int)(ceil(distance / 100) * antennaMessageDelay)` ticks, and the config default is 3.
- Range is the receiver's: a tower reaches 3000 (2400 in a storm), and a mini antenna reaches 650 in both cases (config bug). A storm means the sender world is raining and thundering. The registry requires the same world and a distance greater than 0.
- A complete tower with no computers attached re-transmits each new message id once, adding to the distance. The sending tower does not record its own id, so a repeater echoes the message back to the sender.
- A tower only registers with `BitNetRegistry` from `updateEntity` once its structure is complete, so an incomplete tower neither receives nor repeats. Mini antennas always register and never repeat.

## Computronics 1.6.4-0.4.2 (cipher block)
- The block is exposed through OpenPeripheral (freeform), not natively. Its type comes from the inventory name `asielib.inventory.null`, which gives `asielib_inventory_null`. This name has medium confidence.
- `encrypt(text)` returns Base64 and `decrypt(b64)` returns text. On any failure they return nil, not an error. There is no setLocked.
- The cipher is AES/CBC/PKCS5. The key is built from six slots: per slot, the bytes are id & 255, id >> 8, (dmg & 3) | (size << 2), dmg >> 2 and the NBT hash low byte, and the 32 bytes are folded with XOR to 16. The IV is fixed and derived from damage and NBT. The sim implements real AES (`sim/aes.lua`), so a wrong key returns nil about 255 times in 256 and garbage otherwise.
- The block also has the OpenPeripheral inventory methods.

## OpenPeripheralCore 0.4.1
- From `AdapterInventory`: `pullItem(dir, slot, maxAmount?, intoSlot?)` and `pushItem(...)` return the number of items moved. The other methods are getInventoryName, getInventorySize, getStackInSlot, getAllStacks, condenseItems, swapStacks and destroyStack.
- Directions are absolute lowercase ForgeDirection names: down, up, north, south, west and east.
- From `AdapterEnderAttuned` (tesseract): getOwner, getFrequency, setFrequency (returns a boolean), canSend/canReceive Items/Fluid/Energy.
- Only adapters annotated `@OnTick` run on the server tick. In this jar that is `AdapterInventory` (plus Stargate and Thaumcraft adapters that the sim does not model). Those calls wait on `op_tick_sync` and the calling coroutine loses every other event meanwhile. Everything else runs at once: `AdapterEnderAttuned` (getFrequency, setFrequency, canSend/canReceive), `AdapterSecureTile`, the energy handler adapters, listMethods, and cipher encrypt and decrypt.
- The exact tesseract type name could not be confirmed because there is no TE jar. The default is the configurable `tile_thermalexpansion_tesseract_name`.

## Known gaps
- Tesseract owner and access mode, energy and fluid transfer, and chunk loading are not modelled.
- The wired modem message distance is a Manhattan approximation.
- `computer:output()` captures text written through the bios `write`/`print`/`printError`, not raw `term.write` calls.
- Disk audio is a stub.
- Tesseract item hand-off (a one-slot buffer that delivers after `tesseractDelay` ticks) is a guess, because there is no Thermal Expansion jar. The real tile may push items straight through and refuse them when no receiver has room.
- The wired cable's 256 block range (`TileCable$Peripheral.getTransmitRange`) and hop counting are not modelled.
- Error position prefixes on errors raised by native APIs may differ from LuaJ in some call paths.
