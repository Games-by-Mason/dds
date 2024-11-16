# DDS Zig

A **work in progress** DDS utility for Zig.

# Plan
* [x] Provide DDS header structures for reading DDS files in Zig
* [-] Support converting PNGs to uncompressed DDS files
	* [ ] Support with and without alpha, controlled by a flag (artists shouldn't have to worry about configuring their editors to export alpha or not, fail if alpha requested but missing)
* [ ] Support converting PNGs to BC7 compressed DDS files using [bc7enc_rdo_zig](https://github.com/Games-by-Mason/bc7enc_rdo_zig)
	* Look into whether other modes are needed for alpha, no alpha, normal maps, etc
* [ ] Support applying lossless compression to the resulting DDS
* [ ] Support automatic mipmap generation
* [ ] Consider looking into why lodepng fails UBSAN checks
