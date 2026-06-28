export const compactStepperSx = {
  width: "100%",
  maxWidth: 560,
  mx: "auto",
  minWidth: { xs: 540, md: 0 },
  px: { xs: 0, md: 1.5 },
  py: 0.5,
  "& .MuiStepConnector-root.MuiStepConnector-alternativeLabel": {
    top: 14,
    left: "calc(-50% + 22px)",
    right: "calc(50% + 22px)"
  },
  "& .MuiStepConnector-line": {
    borderColor: "divider",
    borderTopWidth: 2
  },
  "& .MuiStepLabel-label": {
    mt: 0.85,
    color: "text.secondary",
    fontSize: 13,
    fontWeight: 780,
    lineHeight: 1.25
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
    fontWeight: 850
  }
};
