import ballerina/io;

public function main() returns error? {
    int value = checkpanic int:fromString("42");
    io:println(value);
}
