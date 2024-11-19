# DDS Zig

A work in progress DDS utility for Zig.

# Plan
* [x] Provide DDS header structures for reading DDS files in Zig
* [x] Support encoding raw DDS files
* [x] Support encoding BC7 DDS files using [bc7enc_rdo](https://github.com/richgel999/bc7enc_rdo)
* [x] Get flags right/support conversions for...
	* [x] Alpha premul
	* [x] SRGB (keep in mind may not be supported w/ RDO)
* [-] Support useful features
	* [x] Lossless compression on export
	* [ ] Y flip in raw mode (or remove from bc7 mode)
	* [ ] Automatic mipmap generation
	* [ ] Packing channels from separate images
	* [ ] Double check for missing flags from bc7enc that affect bc7
* [ ] Polish
	* [ ] Check length of data when decoding
	* [ ] Upstream encoder does useless copies, consdier working around
	* [ ] Some upstream libraries fail safety checks in debug mode
* [ ] Document usage
