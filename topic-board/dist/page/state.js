/** The queues in display order. Kept here because page scripts cannot load modules outside dist/page. */
export const QUEUES = ["high", "normal", "later"];
export const QUEUE_LABEL = { high: "高", normal: "一般", later: "待辦" };
export const LIGHT_LABEL = {
    decide: "待你決定",
    stuck: "卡住",
    working: "進行中",
    done: "完成",
    unknown: "未知",
};
export const WRITE_LABEL = {
    sending: "送出中",
    retrying: "重試中",
    delivered: "已送達",
    handled_elsewhere: "已由別處處理",
    failed: "失敗",
    undelivered: "未送達",
    unknown: "結果不明",
    ignored: "已忽略",
};
export const BAD_WRITES = ["failed", "undelivered", "unknown"];
export function currentTopic() {
    const match = /^#\/topic\/(.+)$/.exec(location.hash);
    return match === null ? null : decodeURIComponent(match[1]);
}
