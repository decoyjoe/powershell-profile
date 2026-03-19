# posh-git-go-vroom

A heavily optimized fork of [posh-git 0.7.3](https://github.com/dahlbyk/posh-git/tree/v0.7.3) that prioritizes module loading speed above all else.

The original posh-git module takes ~2 seconds to import. This version loads in ~300ms by removing unused features and optimizing for only the features that I personally need.

This is vendored here rather than upstream the changes because it's aggressively customized to my specific workflow, making it much less suitable for general use (unless you use your computer exactly like I do!).
