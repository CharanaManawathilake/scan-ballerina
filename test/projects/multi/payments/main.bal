import ballerina/io;

// Issue: public function that is not isolated.
public function charge(decimal amount) returns decimal {
    return amount;
}

public function main() {
    decimal total = charge(10.5);
    // Issue: both sides of the comparison are the same.
    if total == total {
        io:println(total);
    }
}
