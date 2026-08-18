#include <iostream>
#include "calc.h"

int main() {
    std::cout << "Hello from the C++ app! 2 + 3 = " << calc::add(2, 3)
              << ", 4 * 5 = " << calc::multiply(4, 5) << std::endl;
    return 0;
}
