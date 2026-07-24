--------------------------------------------------------------------------------
-- Report Monitoring — job list query with dispatcher process-count roll-up.
--
-- Adds five columns consumed by the "Route" column of the Job List grid:
--   EXEC_COUNT      number of dispatcher executions for the job
--   CNT_TERMINATED  processes in SUCCESS
--   CNT_RUNNING     processes in RUNNING
--   CNT_WAITING     processes in WAITING or NEW
--   CNT_ERROR       processes in CRASHED or FAILED (blocking and non-blocking)
--
-- Join path:
--   TA_DI_REP_JOBFILE.JOB_ID
--     = DISPATCHER.EXECUTION_INPUT.TAG_EXTERNAL_JOB_ID
--     -> DISPATCHER.EXEC_PROCESSES.EXEC_ID
--
-- The roll-up is a single pre-aggregated inline view joined once, rather than
-- four correlated subqueries. See the performance notes at the bottom.
--------------------------------------------------------------------------------

SELECT
    0 select_status,
    JOB_ID,
    JOB_TMSTMP,
    (
        SELECT
            DOC_USR_DEF
        FROM
            TA_DI_REP_DOC
        WHERE
            DOC_STAT = 'Y'
            AND DOC_ID = JOB_DOC_ID
    ) REPORT_NAME,
    JOB_OPRN_ID,
    JOB_DOC_FRQ,
    CASE JOB_TRAITE
        WHEN 'Q'   THEN 'EMAIL'
        WHEN 'M'   THEN 'EMAIL'
        WHEN 'Z'   THEN 'CFT'
        WHEN 'X'   THEN 'CFT'
        WHEN 'U'   THEN 'MQSeries'
        WHEN 'L'   THEN 'MQSeries'
        WHEN 'O'   THEN 'FAX'
        WHEN 'D'   THEN 'FTP'
        WHEN 'G'   THEN 'FTP'
        WHEN 'B'   THEN 'FTP'
        WHEN 'K'   THEN 'FTP'
        END
        JOB_CHANEL,
    (
        SELECT
            TA_LU_TRANS_ITEM_PROPERTY.VALUE
        FROM
            TA_LU_TRANS_ITEM,
            TA_LU_TRANS_ITEM_PROPERTY
        WHERE
            TA_LU_TRANS_ITEM_PROPERTY.ITEM_ID = TA_LU_TRANS_ITEM.ITEM_ID
            AND TA_LU_TRANS_ITEM.TABLE_ID = 'JOBFILE_STATUS'
            AND TA_LU_TRANS_ITEM_PROPERTY.STATUS = 'Y'
            AND TA_LU_TRANS_ITEM.STATUS = 'Y'
            AND TA_LU_TRANS_ITEM.ITEM_CODE = JOB_TRAITE
    ) STATUS,
    JOB_ENDTIME,
    JOB_DES_NUMERO,
    JOB_DESNAME,
    JOB_DESFORMAT,
    JOB_DESTYPE,
    JOB_COP,
    JOB_OPRN,
    JOB_LNG_ID,
    JOB_DES_FAX,
    JOB_NTFC,
    JOB_REG,
    JOB_DATE_INF,
    JOB_DATE_SUP,
    JOB_EOD_ID,
    JOB_EMAIL,
    JOB_DIR,
    JOB_PARAMETER_STRING,
    JOB_QUEUE,
    JOB_NB_EXEC,
    SENDING_ON_DEMAND,
    CASE
        WHEN D.SENDING_ON_DEMAND = 'N' THEN 'N'
        ELSE MFTALU1.PKG_UTILS_REPORT.FS_GETCOPYREPORT_FLG(J.JOB_ID)
        END
        SENDING_REP_COPY_FLG,
    JOB_TRAITE,
    JOB_DOC_RESTARTABLE,
    COS_ID,
    COS_FILE_SIZE,
    ---------------------------------------------------------------------------
    -- Dispatcher roll-up for the Route column
    ---------------------------------------------------------------------------
    COALESCE(X.EXEC_COUNT,     0) AS EXEC_COUNT,
    COALESCE(X.CNT_TERMINATED, 0) AS CNT_TERMINATED,
    COALESCE(X.CNT_RUNNING,    0) AS CNT_RUNNING,
    COALESCE(X.CNT_WAITING,    0) AS CNT_WAITING,
    COALESCE(X.CNT_ERROR,      0) AS CNT_ERROR
FROM
    MFTALU1.TA_DI_REP_JOBFILE J,
    MFTALU1.TA_DI_REP_DOC D
        LEFT JOIN (
        SELECT
            EI.TAG_EXTERNAL_JOB_ID                                                    AS JOB_ID,
            COUNT(DISTINCT EI.EXEC_ID)                                                AS EXEC_COUNT,
            SUM(CASE WHEN EP.EXEC_PROCESS_STATUS = 'SUCCESS'          THEN 1 ELSE 0 END) AS CNT_TERMINATED,
            SUM(CASE WHEN EP.EXEC_PROCESS_STATUS = 'RUNNING'          THEN 1 ELSE 0 END) AS CNT_RUNNING,
            SUM(CASE WHEN EP.EXEC_PROCESS_STATUS IN ('WAITING','NEW') THEN 1 ELSE 0 END) AS CNT_WAITING,
            SUM(CASE WHEN EP.EXEC_PROCESS_STATUS IN ('CRASHED','FAILED') THEN 1 ELSE 0 END) AS CNT_ERROR
        FROM
            DISPATCHER.EXECUTION_INPUT EI
                JOIN DISPATCHER.EXEC_PROCESSES EP
                     ON EP.EXEC_ID = EI.EXEC_ID
        GROUP BY
            EI.TAG_EXTERNAL_JOB_ID
    ) X
                  ON X.JOB_ID = J.JOB_ID
WHERE
    J.JOB_DOC_ID = D.DOC_ID
ORDER BY
    J.JOB_TMSTMP DESC NULLS LAST;


--------------------------------------------------------------------------------
-- PERFORMANCE NOTES — read before deploying
--------------------------------------------------------------------------------
--
-- 1. The inline view above aggregates the WHOLE of EXECUTION_INPIT/EXEC_PROCESSES
--    before joining. That is fine when those tables are small, and wrong once
--    they are not. The job list is already filtered (typically JOB_TMSTMP >
--    today), so the driving row set is small while the inline view is not.
--
--    If EXEC_PROCESSES is large, push the job filter INTO the inline view so
--    Oracle can prune it, e.g. by correlating on the same date predicate the
--    outer query uses, or by adding:
--
--        WHERE EI.TAG_EXTERNAL_JOB_ID IN (
--            SELECT JOB_ID FROM MFTALU1.TA_DI_REP_JOBFILE
--            WHERE JOB_TMSTMP > :p_from_date
--        )
--
--    Check the plan with the real filter bind values before choosing.
--
-- 2. TAG_EXTERNAL_JOB_ID must be indexed:
--
--        CREATE INDEX DISPATCHER.IX_EXEC_INPUT_TAG_JOB_ID
--            ON DISPATCHER.EXECUTION_INPUT (TAG_EXTERNAL_JOB_ID);
--
--    EXEC_PROCESSES.EXEC_ID should already be indexed as an FK; verify.
--
-- 3. Datatype mismatch is the most likely correctness trap here.
--    TAG_EXTERNAL_JOB_ID is a tag column and may be VARCHAR2 while
--    TA_DI_REP_JOBFILE.JOB_ID is NUMBER. If so, this join will either raise
--    ORA-01722 or silently disable index use through an implicit conversion.
--    Confirm the types and make the cast explicit and index-friendly — cast the
--    NUMBER side, not the indexed VARCHAR2 side:
--
--        ON X.JOB_ID = TO_CHAR(J.JOB_ID)
--
--    and correspondingly GROUP BY the raw VARCHAR2 column as written above.
--
-- 4. CNT_ERROR intentionally merges blocking and non-blocking FAILED plus
--    CRASHED into one bucket, matching the four circles in the UI. The
--    executions detail query still distinguishes them via
--    cnt_blocking_failed / cnt_non_blocking_failed, which is what drives
--    exec_display_status.
--
-- 5. The old-style comma join in the FROM clause is retained to keep the diff
--    small, but mixing it with ANSI LEFT JOIN as done here is legal yet hard to
--    read. Converting the whole statement to ANSI joins is recommended:
--
--        FROM MFTALU1.TA_DI_REP_JOBFILE J
--             JOIN MFTALU1.TA_DI_REP_DOC D ON J.JOB_DOC_ID = D.DOC_ID
--             LEFT JOIN ( ... ) X ON X.JOB_ID = J.JOB_ID
--
--------------------------------------------------------------------------------
