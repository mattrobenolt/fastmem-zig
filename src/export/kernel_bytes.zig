const fastmem = @import("fastmem");

// Keep each entry live without any additional code in the object.
export const copy = fastmem.abi.memcpy;
export const move = fastmem.abi.memmove;
export const set = fastmem.abi.memset;
