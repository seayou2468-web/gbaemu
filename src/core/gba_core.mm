// This translation unit intentionally stays empty.
//
// Historically, it `#include`d files from `gba_core_modules/*.mm` to form a
// single unified implementation. The current build compiles those module files
// as independent translation units, so including them here causes duplicate
// symbol errors at link time.
