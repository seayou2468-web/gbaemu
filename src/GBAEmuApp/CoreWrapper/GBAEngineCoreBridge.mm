// iOS app target bridge TU:
// Compile core C API implementation within the app target so GBAEngine.mm symbols resolve.
// This keeps iOS side connected to core without introducing extra frontend frameworks.

#import "../../core/gba_core_c_api.cpp"
