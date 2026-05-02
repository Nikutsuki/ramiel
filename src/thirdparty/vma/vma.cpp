#define VMA_IMPLEMENTATION
#define VMA_STATIC_VULKAN_FUNCTIONS 0 // Prevent VMA from trying to link symbols
#define VMA_DYNAMIC_VULKAN_FUNCTIONS 0 // We will provide the pointers ourselves
#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"