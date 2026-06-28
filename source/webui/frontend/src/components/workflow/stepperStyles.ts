export const compactStepperSx = {
  width: "100%",
  maxWidth: 520,
  mx: "auto",
  minWidth: { xs: 500, md: 0 },
  px: { xs: 0, md: 2 },
  py: 0.25,
  "& .MuiStepConnector-root.MuiStepConnector-alternativeLabel": {
    top: 12,
    left: "calc(-50% + 20px)",
    right: "calc(50% + 20px)"
  },
  "& .MuiStepConnector-line": {
    borderColor: "divider",
    borderTopWidth: 2
  },
  "& .MuiStepLabel-label": {
    mt: 0.75,
    color: "text.secondary",
    fontSize: 12,
    fontWeight: 780,
    lineHeight: 1.25
  },
  "& .MuiStepLabel-label.Mui-active, & .MuiStepLabel-label.Mui-completed": {
    color: "text.primary"
  },
  "& .MuiStepIcon-root": {
    width: 24,
    height: 24,
    color: "divider"
  },
  "& .MuiStepIcon-root.Mui-active, & .MuiStepIcon-root.Mui-completed": {
    color: "primary.main"
  },
  "& .MuiStepIcon-text": {
    fontSize: 9,
    fontWeight: 850
  }
};
