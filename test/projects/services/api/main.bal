import ballerina/io;

// Issue: parameter `verbose` is never used.
function greet(string name, boolean verbose) returns string {
    return "Hello, " + name;
}

public function main() {
    io:println(greet("api", false));
}
