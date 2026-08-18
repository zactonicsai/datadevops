#include <gtest/gtest.h>
#include "calc.h"

TEST(CalcTest, Add) {
    EXPECT_EQ(calc::add(2, 3), 5);
    EXPECT_EQ(calc::add(2, -3), -1);
}

TEST(CalcTest, Multiply) {
    EXPECT_EQ(calc::multiply(4, 5), 20);
    EXPECT_EQ(calc::multiply(4, 0), 0);
}
