pub const c = @cImport({
    @cInclude("vk_mem_alloc.h");
    @cInclude("stb_image.h");
    @cInclude("stb_image_resize2.h");
});
