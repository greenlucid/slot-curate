I just lost a few hours progress thanks to trusting Remix IDE to store my stuff
I will do frequent commits to make sure I don't go around losing history again.
Thankfully not much was lost. I remember most of the changes and I've kept track of the important stuff with my notes.

This repo is intended for archival, not usage of any kind!
Contract may be filled with unprofessional notes. Will attempt to get the "proper" solidity comment style later, but for now I just want to get it done.

# Slot Curate

A complete overhaul of Curate to make it as gas efficient as theoretically possible (theoretically possible means, I haven't come up with a better way.)
Main innovation is standarizing "slots" to be rewritten later, because writing storage in used slots is way cheaper.
Instead of keeping around trash data, reuse that space for cheaper usage.

Most of the work will be done by the subgraph.
And it is very difficult to do this without changing much of the interfaces. Kleros Arbitrable standards will be kept (and attempt will be made)
But main priority is keeping mainline use cases extremely cheap
