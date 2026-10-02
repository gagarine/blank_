import { type Command } from "prosemirror-state";
import { addRowAfter, goToNextCell, isInTable } from "prosemirror-tables";

// One transaction (and undo step): Tab from the last cell extends the table.
export const nextTableCell: Command = (state, dispatch) => {
  if (goToNextCell(1)(state, dispatch)) return true;
  if (!isInTable(state)) return false;
  return addRowAfter(
    state,
    dispatch &&
      ((tr) => {
        goToNextCell(1)(state.apply(tr), (selection) =>
          tr.setSelection(selection.selection),
        );
        dispatch(tr.scrollIntoView());
      }),
  );
};
