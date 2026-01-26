DROP TABLE IF EXISTS dbo.tbl_Contracts;

SELECT
    CRHD.CONTRACT_CODE AS ContractCode,
    CRHD.CONTRACT_REF AS ContractReference,
    CS.DESCRIPTION AS ContractSource,
    CTP.DESCRIPTION AS ContractType,
    CRHD.CONT_VALUE AS ContractValue,
    CRHD.END_DATE AS ContractEndDate,
    CRHD.INV_NDEL AS ContractAutoConfirmInvoice,
    CRHD.REVIEW_DATE AS ContractLastReviewDate,
    CRHD.LSTATUS_DATE AS ContractLastStatusChangeDate,
    CRHD.ORIGINATOR_DET1 AS ContractOriginatorDetails1,
    CRHD.ORIGINATOR_DET2 AS ContractOriginatorDetails2,
    CRHD.ORIG_START_DATE AS ContractOriginalStartDate,
    CRHD.PAY_NDEL AS ContractAutoConfirmPay,
    CRHD.REVIEW_DATE AS ContractReviewDate,
    CRHD.START_DATE AS ContractStartDate,
    CST.DESCRIPTION AS ContractStatus,
    CRHD.VATABLE AS ContractVatableServices,
    CRHD.VATCODE AS ContractVATCode,
    CASE CRHD.CONTCMTYPE
        WHEN '0' THEN 'Internal Call Monitoring'
        WHEN 'I' THEN 'Internal Call Monitoring'
        WHEN 'Y' THEN 'CM2000'
        WHEN 'E' THEN 'eziTracker'
        WHEN 'O' THEN 'Over-C'
        WHEN 'S' THEN 'SunGuard'
        WHEN 'T' THEN 'Tallon'
        WHEN 'N' THEN 'None'
        ELSE NULL
    END AS ContractCMType,
    CRHD.CAL_REF AS CalendarReference,
    CRHD.PALLC_DAYS AS ContractPeriodAllocationDays,
    CRHD.PALLC_MONS AS ContractPeriodAllocationMonths,
    CRHD.CONTRACTHR AS ContractedHoursPerWeek,
    CRHD.PROV_NAME AS ContractProviderName,
    CASE CRHD.BILLING
        WHEN '0' THEN 'Internal Call Monitoring'
        WHEN 'N' THEN 'DEVorting Only'
        WHEN 'P' THEN 'Invoice Only'
        WHEN 'R' THEN 'Pay Only'
        WHEN ''  THEN 'Invoice and Pay'
        ELSE NULL
    END AS ContractUse,
    CO.CORG_CODE AS ContractOrganisationCode,
    CO.CORG_DESC AS ContractOrganisationDescription,
    CO.CORG_TYPE AS ContractOrganisationType,
    CRDT.CONT_DET_REF AS ContractDetailReference,
    CCB.DESCRIPTION AS ContractChargeBand,
    CHD.ACCOUNT_NO AS ContractFundSourceAccountNo,
    CHD.ANALYSIS AS ContractAnalysisCode,
    CHD.SURNAME AS ContractFundSourceName,
    CIT.DESCRIPTION AS ContractInvoiceType,
    CASE CINT.DESCRIPTION
        WHEN 'D' THEN 'Direct'
        WHEN 'M' THEN 'Manual'
        ELSE NULL
    END AS ContractInterfaceType,
    CFT.DESCRIPTION AS ContractFundSourceType,
    ISNULL(PL.PLH_REF, 0) AS [$PriceListReference]
INTO dbo.tbl_Contracts
FROM [dbo].CONTRACT_HD AS CRHD WITH (NOLOCK)
LEFT JOIN [dbo].CONTRACT_DT AS CRDT WITH (NOLOCK)
    ON CRHD.CONTRACT_REF = CRDT.CONTRACT_REF AND CRDT.CONT_DET_TYPE = 1
LEFT JOIN [dbo].CONTRACT_ORG AS CO WITH (NOLOCK)
    ON CRHD.CORG_REF = CO.CORG_REF
LEFT JOIN[dbo].CONTACT_DT AS CDT WITH (NOLOCK)
    ON CDT.CNTA_DET_REF = CRHD.CNTA_DET_REF
LEFT JOIN [dbo].CONTACT_HD AS CHD WITH (NOLOCK)
    ON CHD.CONTACT_REF = CDT.CONTACT_REF
LEFT JOIN [dbo].CHSYSDEC AS CCB WITH (NOLOCK)
    ON CRDT.CHARGE_BAND = CCB.DECODE_REF
LEFT JOIN [dbo].CHSYSDEC AS CS WITH (NOLOCK)
    ON CRHD.CONTRACT_SOURCE = CS.DECODE_REF
LEFT JOIN [dbo].CHSYSDEC AS CIT WITH (NOLOCK)
    ON CIT.DECODE_REF = CHD.INTERTYPE
LEFT JOIN [dbo].CHSYSDEC AS CINT WITH (NOLOCK)
    ON CINT.DECODE_REF = CHD.INVOICE_TYPE
LEFT JOIN [dbo].CHSYSDEC AS CFT WITH (NOLOCK)
    ON CFT.DECODE_REF = CHD.FSTYPE
LEFT JOIN [dbo].CHSYSDEC AS CST WITH (NOLOCK)
    ON CST.DECODE_REF = CRHD.STATUS
LEFT JOIN [dbo].CHSYSDEC AS CTP WITH (NOLOCK)
    ON CTP.DECODE_REF = CRHD.CONTRACT_TYPE
LEFT JOIN [dbo].CONTRULE_HD AS CR WITH (NOLOCK)
    ON CR.CONTRACT_REF = CRHD.CONTRACT_REF
    AND CR.RECTYPE = 'L'
    AND CR.ENDDATE >= GETDATE()
LEFT JOIN [dbo].PRICELIST_HD AS PL WITH (NOLOCK)
    ON PL.PLH_REF = CR.PLH_REF;

-- Note: The filter on CRDT.CONT_DET_TYPE is now in the JOIN instead of WHERE.
