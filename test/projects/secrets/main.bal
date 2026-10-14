import ballerina/io;

type Credentials record {|
    string username;
    string password;
|};

isolated function loadPassword() returns string {
    return "value";
}

public isolated function main() {
    // Issue: a secret that is not configurable.
    Credentials credentials = {username: "admin", password: loadPassword()};
    io:println(credentials.username);
}
