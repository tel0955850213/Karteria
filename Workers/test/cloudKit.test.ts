import assert from "node:assert/strict";
import test from "node:test";

import { cloudKitModifyPayload, field, record } from "../src/cloudKit";

test("uses non-atomic writes for the public default zone", () => {
    const operations = [{
        operationType: "create" as const,
        record: record("probe", "ContentReport", { state: field("resolved") }),
    }];

    assert.deepEqual(cloudKitModifyPayload(operations), {
        operations,
        atomic: false,
    });
});
