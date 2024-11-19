# DDS Zig

A work in progress DDS utility for Zig.

# Plan
* [x] Provide DDS header structures for reading DDS files in Zig
* [x] Support encoding raw DDS files
* [x] Support encoding BC7 DDS files using [bc7enc_rdo](https://github.com/richgel999/bc7enc_rdo)
* [ ] Get flags right/support conversions for...
	* [ ] Alpha premul
	* [ ] SRGB (keep in mind may not be supported w/ RDO)
* [ ] Support useful features
	* [ ] Lossless compression on export
	* [ ] Y flip in raw mode (or remove from bc7 mode)
	* [ ] Automatic mipmap generation
* [ ] Polish
	* [ ] Check length of data when decoding
	* [ ] Upstream encoder does useless copies, consdier working around
	* [ ] Some upstream libraries fail safety checks in debug mode
* [ ] Document usage
