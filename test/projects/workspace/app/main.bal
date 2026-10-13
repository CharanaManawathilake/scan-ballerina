import ballerina/io;
import scan_test/greeter;

public function main() {
    io:println(greeter:greet("World"));
}
