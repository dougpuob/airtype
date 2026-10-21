export const compactStepperSx = {
  width: "100%",
  maxWidth: 560,
  mx: "auto",
  minWidth: { xs: 0, md: 0 },
  px: { xs: 0, md: 1.5 },
  py: 0.5,
  "& .MuiStepConnector-root.MuiStepConnector-alternativeLabel": {
    top: 14,
    left: "calc(-50% + 22px)",
    right: "calc(50% + 22px)"
  },
  "& .MuiStepConnector-root.MuiStepConnector-vertical": {
    ml: "13px"
  },
  "& .MuiStepConnector-line": {
    borderColor: "divider",
    borderTopWidth: 2
  },
  "& .MuiStepConnector-vertical .MuiStepConnector-line": {
    borderLeftWidth: 2,
    minHeight: 16
  },
  "& .MuiStepLabel-label": {
    mt: { xs: 0, md: 0.85 },
    color: "text.secondary",
    fontSize: { xs: 13, md: 13 },
    fontWeight: 600,
    lineHeight: 1.25,
    whiteSpace: { xs: "normal", md: "nowrap" }
  },
  "& .MuiStepLabel-label.Mui-active, & .MuiStepLabel-label.Mui-completed": {
    color: "text.primary"
  },
  "& .MuiStepIcon-root": {
    width: 28,
    height: 28,
    color: "divider"
  },
  "& .MuiStepIcon-root.Mui-active, & .MuiStepIcon-root.Mui-completed": {
    color: "primary.main"
  },
  "& .MuiStepIcon-text": {
    fontSize: 10,
    fontWeight: 700
  }
};
