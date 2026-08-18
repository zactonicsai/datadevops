package com.example;

import static org.junit.jupiter.api.Assertions.assertEquals;
import org.junit.jupiter.api.Test;

class AppTest {
    @Test
    void addsTwoNumbers() {
        assertEquals(5, App.add(2, 3));
    }

    @Test
    void addsNegativeNumbers() {
        assertEquals(-1, App.add(2, -3));
    }
}
