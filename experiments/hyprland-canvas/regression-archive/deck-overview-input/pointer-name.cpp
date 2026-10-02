#include <cstdlib>
#include <string>

extern "C" const std::string& pointerName(void*) asm("_ZN10Aquamarine15CWaylandPointer7getNameB5cxx11Ev");
extern "C" const std::string& pointerName(void*) {
    static const std::string name = std::getenv("CANVAS_TEST_POINTER_NAME");
    return name;
}
