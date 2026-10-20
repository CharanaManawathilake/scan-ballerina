import ballerina/io;

public function main() {
    // Issue: checkpanic instead of check.
    int code = checkpanic int:fromString("1");
    // Issue: variable assigned to itself.
    code = code;
    io:println(code);
}
