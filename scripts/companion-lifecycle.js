ObjC.import("AppKit");
ObjC.import("Foundation");

function normalizedPath(value) {
    return ObjC.unwrap($.NSURL.fileURLWithPath(value).URLByStandardizingPath.path);
}

function exactApplications(bundleIdentifier, expectedPath) {
    const expected = normalizedPath(expectedPath);
    const expectedExecutable = normalizedPath(expectedPath + "/Contents/MacOS/Human in the Whoop");
    const running = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(bundleIdentifier);
    const matches = [];
    for (let index = 0; index < running.count; index += 1) {
        const application = running.objectAtIndex(index);
        if (application.bundleURL && application.executableURL
            && normalizedPath(ObjC.unwrap(application.bundleURL.path)) === expected
            && normalizedPath(ObjC.unwrap(application.executableURL.path)) === expectedExecutable) {
            matches.push(application);
        }
    }
    return matches;
}

function pauseBriefly() {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05));
}

function waitFor(bundleIdentifier, expectedPath, wantedRunning, timeoutSeconds) {
    const deadline = Date.now() + timeoutSeconds * 1000;
    while (Date.now() <= deadline) {
        const isRunning = exactApplications(bundleIdentifier, expectedPath).length > 0;
        if (isRunning === wantedRunning) return true;
        pauseBriefly();
    }
    return false;
}

function run(argv) {
    if (argv.length !== 4) throw new Error("invalid lifecycle arguments");
    const action = argv[0];
    const bundleIdentifier = argv[1];
    const expectedPath = argv[2];
    const timeoutSeconds = Number(argv[3]);
    if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 30) {
        throw new Error("invalid lifecycle timeout");
    }

    if (action === "probe") {
        return exactApplications(bundleIdentifier, expectedPath).length > 0 ? "running" : "stopped";
    }
    if (action === "terminate") {
        const applications = exactApplications(bundleIdentifier, expectedPath);
        for (const application of applications) {
            // JXA exposes zero-argument Objective-C methods as properties.
            // Reading this member invokes -[NSRunningApplication terminate].
            if (!application.terminate) throw new Error("companion refused termination");
        }
        if (!waitFor(bundleIdentifier, expectedPath, false, timeoutSeconds)) {
            throw new Error("companion termination timed out");
        }
        return "stopped";
    }
    if (action === "wait-running") {
        if (!waitFor(bundleIdentifier, expectedPath, true, timeoutSeconds)) {
            throw new Error("installed companion did not start in time");
        }
        return "running";
    }
    throw new Error("unknown lifecycle action");
}
