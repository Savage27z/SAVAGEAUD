Hey — quick one, no drama intended.

I've been auditing DeathFun and found a real defect in `increaseBet()`. Two checks are
missing: it never verifies that the ETH actually sent matches the `amount` it credits, and
the server signature it accepts is never marked as used, so the same one works repeatedly.

On a local copy of your deployed contract (forked bytecode, not your live one) I credited a
35 ETH bet for a 1 wei payment by replaying one signature 7 times.

I'm not touching your live contract without your say-so, so — your call:

1. Say the word and I'll demonstrate it live on mainnet with my own wallet (~$3 of ETH),
   and send you the tx hash + screenshot. Or,
2. I send the full writeup + the fork reproduction + the fix, and nothing ever goes near
   your live contract.

Either is fine. #2 is less hassle for you and honestly proves the same thing.

Fix is small: bind `msg.value` into the signed hash (the way `createGame` already does) and
track consumed signatures. Happy to hand over the exact diff.

One thing worth saying up front: I went back through all 7,329 historical `increaseBet`
calls. Every one attached the correct amount and no signature was ever reused — so this
hasn't been exploited and there's no bad state to clean up. This is a hardening report, not
an incident.

Want me to send the writeup?
