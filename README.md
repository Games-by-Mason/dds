# DDS Zig

A **work in progress** DDS utility for Zig.

# Plan
* [x] Provide DDS header structures for reading DDS files in Zig
* [x] Support converting PNGs to uncompressed DDS files with and without alpha
* [ ] Support converting PNGs to BC7 compressed DDS files using [bc7enc_rdo_zig](https://github.com/Games-by-Mason/bc7enc_rdo_zig)
* [ ] Look into whether other modes are needed for alpha, no alpha, normal maps, etc
* [ ] Look into srgb/alpha premul conversions
* [ ] Support applying lossless compression to the resulting DDS
* [ ] Support automatic mipmap generation
* [ ] Check length of data when decoding
* [ ] Look into why lodepng fails UBSAN