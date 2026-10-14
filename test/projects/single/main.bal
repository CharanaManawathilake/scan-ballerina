import ballerina/io;

class Counter {
    private int count = 0;
    // Issue: private field that is never used.
    private int unused = 0;

    function increment() {
        self.count += 1;
    }

    function get() returns int {
        return self.count;
    }
}

// Issues: public function that is not isolated, and parameter `b` is never used.
public function add(int a, int b) returns int {
    return a;
}

public function main() returns error? {
    // Issue: checkpanic instead of check.
    int value = checkpanic int:fromString("42");

    // Issue: variable assigned to itself.
    value = value;

    // Issue: both sides of the comparison are the same.
    if value == value {
        io:println("always true");
    }

    Counter counter = new;
    counter.increment();
    io:println(add(value, counter.get()));
}
